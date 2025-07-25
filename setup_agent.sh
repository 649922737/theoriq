#!/bin/bash

# --- 1. 前提条件检查与提醒 ---
echo "--- Theoriq AI 代理自动化设置脚本 (Mac OS) ---"
echo "--- 请确保已安装 Rust (版本 1.79 或更高) ---"
echo "--- 您可以通过 'rustc --version' 检查 Rust 版本。如果未安装，请运行此命令安装："
echo "--- curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
echo "--------------------------------------------------"

# 检查 Rust 是否安装
if ! command -v rustc &> /dev/null
then
    echo "错误：未检测到 Rust。请先安装 Rust，然后重新运行此脚本。"
    exit 1
fi

echo "Rust 已安装，继续..."

# --- 2. 配置变量 ---
AGENT_PROJECT_NAME="my_theoriq_agent" # 您代理项目文件夹的名称
THEORIQ_URI="https://theoriq-backend.prod-02.chainml.net" # Theoriq 后端 URI

# --- 3. 克隆 Theoriq SDK 仓库并生成私钥 ---
echo "--- 克隆 Theoriq SDK 仓库并生成代理私钥 ---"
SDK_REPO_DIR="theoriq-agent-sdk-source"
if [ -d "$SDK_REPO_DIR" ]; then
    echo "检测到 '$SDK_REPO_DIR' 目录已存在，跳过克隆。"
    cd "$SDK_REPO_DIR"
    git pull # 更新一下仓库，以防万一
else
    echo "正在克隆 Theoriq SDK 仓库到 '$SDK_REPO_DIR'..."
    git clone https://github.com/chain-ml/theoriq-agent-sdk.git "$SDK_REPO_DIR"
    if [ $? -ne 0 ]; then
        echo "错误：克隆 Theoriq SDK 仓库失败。请检查您的网络连接和 Git 设置。"
        exit 1
    fi
    cd "$SDK_REPO_DIR"
fi

echo "正在生成代理私钥..."
# 运行私钥生成脚本并捕获输出
PRIVATE_KEY_OUTPUT=$(PYTHONPATH=.. python3 scripts/generate_private_key.py)
if [ $? -ne 0 ]; then
    echo "错误：生成私钥脚本运行失败。"
    exit 1
fi

AGENT_PRIVATE_KEY=$(echo "$PRIVATE_KEY_OUTPUT" | grep 'AGENT_PRIVATE_KEY' | awk '{print $3}')
AGENT_PUBLIC_KEY=$(echo "$PRIVATE_KEY_OUTPUT" | grep 'Corresponding public key' | awk '{print $4}' | tr -d '\`')

if [ -z "$AGENT_PRIVATE_KEY" ] || [ -z "$AGENT_PUBLIC_KEY" ]; then
    echo "错误：未能从脚本输出中提取私钥或公钥。请手动检查输出。"
    echo "脚本输出：$PRIVATE_KEY_OUTPUT"
    exit 1
fi

echo "私钥已生成并捕获。"
echo "请妥善保管您的私钥：$AGENT_PRIVATE_KEY"
echo "您的公钥（用于注册）：$AGENT_PUBLIC_KEY"
echo "--------------------------------------------------"

# 返回到脚本运行的初始目录
cd ..

# --- 4. 创建代理项目文件夹并设置 Python 环境 ---
echo "--- 创建代理项目文件夹并设置 Python 环境 ---"
if [ -d "$AGENT_PROJECT_NAME" ]; then
    echo "检测到项目目录 '$AGENT_PROJECT_NAME' 已存在，将使用现有目录。"
    cd "$AGENT_PROJECT_NAME"
else
    echo "正在创建项目目录 '$AGENT_PROJECT_NAME'..."
    mkdir "$AGENT_PROJECT_NAME"
    cd "$AGENT_PROJECT_NAME"
fi

echo "正在创建虚拟环境并激活..."
python3 -m venv venv
source venv/bin/activate # 这里激活是为了后续 pip install 能在 venv 中进行

# --- 确保 pip 升级步骤正确执行 ---
echo "--- 升级 pip ---"
if ! pip install --upgrade pip; then
    echo "警告：升级 pip 失败。这可能会导致后续依赖安装问题。但仍将尝试安装依赖。"
fi
echo "--------------------------------------------------"

echo "正在创建 requirements.txt 文件..."
cat << EOF > requirements.txt
python-dotenv==1.0.*
flask>=3.1.0
# 修正 egg 名为 'theoriq'，与包内部元数据保持一致
git+https://github.com/chain-ml/theoriq-agent-sdk.git#egg=theoriq[flask]
EOF

echo "正在安装 Python 依赖..."
pip install -r requirements.txt
if [ $? -ne 0 ]; then
    echo "错误：安装 Python 依赖失败。请检查错误信息或手动解决依赖问题。"
    deactivate # 退出虚拟环境
    exit 1
fi

# --- 诊断步骤：检查 theoriq 是否已安装 ---
echo "--- 诊断：检查 theoriq 是否已安装 ---"
if pip show theoriq &> /dev/null; then # 现在检查包名 'theoriq'
    echo "theoriq (Theoriq Agent SDK) 已成功安装在虚拟环境中。"
else
    echo "错误：theoriq (Theoriq Agent SDK) 未在虚拟环境中找到。安装可能失败了。"
    echo "请检查上面的 pip install 错误信息，或尝试手动在激活虚拟环境后运行 'pip install git+https://github.com/chain-ml/theoriq-agent-sdk.git#egg=theoriq[flask]'"
    deactivate
    exit 1
fi

# --- 诊断步骤：列出已安装的 theoriq 包内容 ---
PYTHON_VERSION_DIR=$(python3 -c "import sys; print(f'python{sys.version_info.major}.{sys.version_info.minor}')")
INSTALLED_PACKAGE_PATH="./venv/lib/$PYTHON_VERSION_DIR/site-packages/theoriq/"

echo "--- 诊断：列出已安装的 theoriq 包内容 ---"
if [ -d "$INSTALLED_PACKAGE_PATH" ]; then
    echo "目录 '$INSTALLED_PACKAGE_PATH' 的内容如下："
    ls -RF "$INSTALLED_PACKAGE_PATH"
else
    echo "警告：未找到已安装的 theoriq 包目录：'$INSTALLED_PACKAGE_PATH'"
    echo "这可能意味着安装失败或包名不正确。请检查 pip install 错误。"
fi
echo "------------------------------------------------------"
echo "--------------------------------------------------"

# --- 5. 创建 main.py 代理脚本 ---
echo "--- 创建 main.py 代理脚本 ---"
cat << EOF > main.py
import os
import dotenv
from flask import Flask
from theoriq.extra.flask.v1alpha2.flask import theoriq_blueprint
from theoriq import AgentDeploymentConfiguration
# 修正 ExecuteRequestBody 的导入路径
from theoriq.api.v1alpha2.schemas.request import ExecuteRequestBody
from theoriq import ExecuteResponse
from theoriq import ExecuteContext
import logging

# 配置日志
logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', force=True)

def execute(context: ExecuteContext, req: ExecuteRequestBody) -> ExecuteResponse:
    logger.info(f"Received request: {context.request_id}")

    if req.last_item and req.last_item.blocks:
        last_block = req.last_item.blocks[0]
        if hasattr(last_block, 'data') and hasattr(last_block.data, 'text'):
            text_value = last_block.data.text
        else:
            text_value = "没有可识别的文本输入"
    else:
        text_value = "没有可识别的输入"

    agent_result = f"Hello {text_value} from a Theoriq Agent!"
    logger.info(f"Agent response: {agent_result}")

    return context.new_response(
        blocks=[
            TextBlock.from_text(text=agent_result),
        ],
    )

if __name__ == "__main__":
    dotenv.load_dotenv()

    try:
        agent_config = AgentDeploymentConfiguration.from_env()
        logger.info("Agent configuration loaded successfully from environment variables.")
    except Exception as e:
        logger.error(f"Failed to load agent configuration from environment variables: {e}")
        logger.error("请确保 AGENT_PRIVATE_KEY 和 THEORIQ_URI 已设置。")
        exit(1)

    app = Flask(__name__)
    blueprint = theoriq_blueprint(agent_config, execute)
    app.register_blueprint(blueprint)

    host = "0.0.0.0"
    port = 8000
    logger.info(f"Starting Theoriq Agent Flask server on {host}:{port}")
    app.run(host=host, port=port, debug=False)

EOF
echo "main.py 脚本已创建。"
echo "--------------------------------------------------"

# --- 6. 设置环境变量并启动 Theoriq 代理 ---
echo "--- 设置环境变量并启动 Theoriq 代理 ---"

# 导出私钥和 URI 到当前 shell 环境
export AGENT_PRIVATE_KEY="$AGENT_PRIVATE_KEY"
export THEORIQ_URI="$THEORIQ_URI"

echo "环境变量已设置。"
echo "AGENT_PRIVATE_KEY=$AGENT_PRIVATE_KEY"
echo "THEORIQ_URI=$THEORIQ_URI"

echo "正在启动 Theoriq 代理..."
echo "按 Ctrl+C 停止代理。"

# 明确使用虚拟环境中的 python 解释器来运行 main.py
./venv/bin/python main.py

echo "--- Theoriq 代理已停止。---"
echo "您可以在 Infinity Hub 注册您的代理：https://infinity.theoriq.ai/hub/agent-register"
echo "使用公钥：$AGENT_PUBLIC_KEY"
echo "--------------------------------------------------"
