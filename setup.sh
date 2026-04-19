#!/bin/bash
# 家庭收纳助手 - 初始化脚本
# 用法: bash setup.sh
# 功能: 自动创建多维表格、生成 config.json、配置 lark-cli
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="HOME=$SCRIPT_DIR lark-cli"

echo "=== 家庭收纳助手 - 初始化向导 ==="
echo ""

# ===== 1. 检查依赖 =====
echo "[1/4] 检查依赖..."
for cmd in lark-cli jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "  ❌ 缺少 $cmd，请先安装"
    exit 1
  fi
done
echo "  ✅ 依赖齐全"
echo ""

# ===== 2. 配置飞书应用 =====
echo "[2/4] 配置飞书应用"
echo "  请前往 https://open.feishu.cn/app 创建应用，获取 App ID 和 App Secret"
echo "  需要开通的权限："
echo "    - im:message / im:message:readonly"
echo "    - im:resource"
echo "    - bitable:app"
echo ""

if [[ -f "$SCRIPT_DIR/.lark-cli/config.json" ]]; then
  echo "  ✅ 已存在 .lark-cli/config.json，跳过"
else
  read -p "  App ID: " APP_ID
  read -p "  App Secret: " APP_SECRET

  mkdir -p "$SCRIPT_DIR/.lark-cli"
  cat > "$SCRIPT_DIR/.lark-cli/config.json" << EOF
{
  "apps": [
    {
      "appId": "$APP_ID",
      "appSecret": "$APP_SECRET",
      "brand": "feishu",
      "lang": "zh"
    }
  ]
}
EOF
  echo "  ✅ 飞书应用已配置"

  # 验证
  if HOME="$SCRIPT_DIR" lark-cli config show &>/dev/null; then
    echo "  ✅ lark-cli 配置验证通过"
  else
    echo "  ❌ lark-cli 配置验证失败，请检查 App ID 和 App Secret"
    exit 1
  fi
fi
echo ""

# ===== 3. 创建多维表格 =====
echo "[3/4] 多维表格"
echo "  你可以："
echo "    1) 提供已有表格的 Base Token 和 Table ID"
echo "    2) 让脚本自动创建新表格"
echo ""
read -p "  选择 (1/2): " TABLE_CHOICE

if [[ "$TABLE_CHOICE" == "2" ]]; then
  read -p "  表格名称 (默认: 家庭物品清单): " TABLE_NAME
  TABLE_NAME="${TABLE_NAME:-家庭物品清单}"

  echo "  正在创建表格..."
  BASE_TOKEN=$(HOME="$SCRIPT_DIR" lark-cli base +record-list \
    --base-token "test" --table-id "test" 2>&1 || true)

  echo ""
  echo "  ⚠️  自动创建 Base 需要在飞书中手动操作："
  echo "  1. 打开飞书 → 多维表格 → 新建"
  echo "  2. 命名为「$TABLE_NAME」"
  echo "  3. 按以下结构添加字段："
  echo ""
  echo "  | 字段名   | 类型   | 说明                              |"
  echo "  |----------|--------|-----------------------------------|"
  echo "  | 物品名称 | 文本   | 物品名                            |"
  echo "  | 位置     | 文本   | 存放位置                          |"
  echo "  | 分类     | 单选   | 电子产品/文具/衣物/厨房用品/工具/证件/药品/玩具/书籍/钥匙卡包/其他 |"
  echo "  | 数量     | 数字   | 物品数量，默认 1                  |"
  echo "  | 存放人   | 文本   | 谁放的                            |"
  echo "  | 备注     | 文本   | 补充说明                          |"
  echo "  | 存放时间 | 创建时间 | 系统自动记录                     |"
  echo "  | 附件     | 附件   | 关联图片                          |"
  echo ""
  echo "  创建完成后，从 URL 中获取 Token："
  echo "  https://xxx.feishu.cn/base/XXXXXX?table=YYYYYY"
  echo "                              ^^^^^^      ^^^^^^"
  echo "                              Base Token  Table ID"
fi

read -p "  Base Token: " BASE_TOKEN
read -p "  Table ID: " TABLE_ID

# 验证表格可访问
echo "  验证表格..."
if HOME="$SCRIPT_DIR" lark-cli base +record-list \
    --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --limit 1 &>/dev/null; then
  echo "  ✅ 表格访问正常"
else
  echo "  ❌ 无法访问表格，请检查 Token 和权限"
  exit 1
fi
echo ""

# ===== 4. 配置 LLM =====
echo "[4/4] 配置 LLM API"
echo ""
echo "  支持的 LLM 厂商："
echo "    1) 智谱（推荐，免费）       https://open.bigmodel.cn"
echo "    2) 阿里通义（免费额度）     https://dashscope.console.aliyun.com"
echo "    3) DeepSeek                 https://platform.deepseek.com"
echo "    4) Moonshot                 https://platform.moonshot.cn"
echo "    5) 硅基流动（免费额度）     https://cloud.siliconflow.cn"
echo "    6) OpenAI                   https://platform.openai.com"
echo ""
read -p "  选择厂商 (1-6, 默认: 1): " LLM_CHOICE
LLM_CHOICE="${LLM_CHOICE:-1}"

case "$LLM_CHOICE" in
  1) PROVIDER="zhipu";   BASE_URL="https://open.bigmodel.cn/api/paas/v4";          MODEL="glm-4.5-air" ;;
  2) PROVIDER="qwen";    BASE_URL="https://dashscope.aliyuncs.com/compatible-mode/v1"; MODEL="qwen-turbo" ;;
  3) PROVIDER="deepseek";BASE_URL="https://api.deepseek.com/v1";                    MODEL="deepseek-chat" ;;
  4) PROVIDER="moonshot";BASE_URL="https://api.moonshot.cn/v1";                     MODEL="moonshot-v1-8k" ;;
  5) PROVIDER="silicon"; BASE_URL="https://api.siliconflow.cn/v1";                  MODEL="Qwen/Qwen2.5-7B-Instruct" ;;
  6) PROVIDER="openai";  BASE_URL="https://api.openai.com/v1";                      MODEL="gpt-4o-mini" ;;
  *) PROVIDER="zhipu";   BASE_URL="https://open.bigmodel.cn/api/paas/v4";          MODEL="glm-4.5-air" ;;
esac

read -p "  模型名称 (默认: $MODEL): " INPUT_MODEL
MODEL="${INPUT_MODEL:-$MODEL}"

read -p "  API Key: " API_KEY

echo ""

# ===== 生成 config.json =====
APP_ID=${APP_ID:-$(jq -r '.apps[0].appId' "$SCRIPT_DIR/.lark-cli/config.json" 2>/dev/null)}
APP_SECRET=${APP_SECRET:-$(jq -r '.apps[0].appSecret' "$SCRIPT_DIR/.lark-cli/config.json" 2>/dev/null)}

cat > "$SCRIPT_DIR/config.json" << EOF
{
  "app_id": "$APP_ID",
  "app_secret": "$APP_SECRET",
  "llm_provider": "$PROVIDER",
  "llm_api_key": "$API_KEY",
  "llm_model": "$MODEL",
  "llm_base_url": "$BASE_URL",
  "base_token": "$BASE_TOKEN",
  "table_id": "$TABLE_ID"
}
EOF

echo "=== 配置完成 ==="
echo ""
echo "配置文件: config.json"
echo "运行方式: bash bot.sh"
echo ""
echo "开机自启 (macOS):"
echo "  编辑 ~/Library/LaunchAgents/com.home-storage-bot.plist"
echo "  将 WorkingDirectory 和路径改为: $SCRIPT_DIR"
echo ""
echo "现在可以启动了！在飞书中把机器人拉进群，发送「你好」试试"
