#!/bin/bash
# 家庭收纳助手 - 飞书机器人（lark-cli 版）
# 用法: bash bot.sh
# 依赖: jq, curl, lark-cli
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/config.json"
SYSTEM_PROMPT="$SCRIPT_DIR/system-prompt.txt"
DATA_DIR="$SCRIPT_DIR/data"
CHATS_FILE="$DATA_DIR/known_chats.txt"
mkdir -p "$DATA_DIR"
touch "$CHATS_FILE"

# 从配置文件读取
LLM_API_KEY=$(jq -r '.llm_api_key' "$CONFIG")
LLM_MODEL=$(jq -r '.llm_model' "$CONFIG")
LLM_BASE_URL=$(jq -r '.llm_base_url' "$CONFIG")
BASE_TOKEN=$(jq -r '.base_token' "$CONFIG")
TABLE_ID=$(jq -r '.table_id' "$CONFIG")
ATTACHMENT_FIELD_ID=$(jq -r '.attachment_field_id // ""' "$CONFIG")

# lark-cli 命令前缀（项目级配置 + bot 身份）
# 用函数代替 eval，避免 JSON 参数被 shell 二次解析
lark() { HOME="$SCRIPT_DIR" lark-cli "$@"; }

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

# ===== 聊天记录 =====
remember_chat() {
  local chat_id="$1"
  grep -qxF "$chat_id" "$CHATS_FILE" 2>/dev/null || echo "$chat_id" >> "$CHATS_FILE"
}

# ===== LLM（智谱） =====
ask_llm() {
  local user_msg="$1"
  local sys_prompt
  sys_prompt=$(cat "$SYSTEM_PROMPT")

  local response
  response=$(jq -n --arg system "$sys_prompt" --arg user "$user_msg" --arg model "$LLM_MODEL" '{
    model: $model,
    messages: [{role: "system", content: $system}, {role: "user", content: $user}],
    max_tokens: 300
  }' \
  | curl -s --max-time 30 \
    "${LLM_BASE_URL}/chat/completions" \
    -H "Authorization: Bearer $LLM_API_KEY" \
    -H "Content-Type: application/json" \
    -d @- 2>/dev/null) || true

  [[ -z "$response" ]] && return 0
  echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true
}

# ===== 飞书 CLI 封装 =====

# 发送文本消息
send_reply() {
  local chat_id="$1" text="$2"
  if [[ ${#text} -gt 4000 ]]; then
    text="${text:0:4000}..."
  fi
  lark im +messages-send \
    --chat-id "$chat_id" \
    --text "$text" \
    --as bot >/dev/null 2>&1
  return 0
}

# 拉取多维表格记录
fetch_records() {
  lark base +record-list \
    --base-token "$BASE_TOKEN" \
    --table-id "$TABLE_ID" \
    --limit 200 2>/dev/null
}

# 创建记录，返回 record_id
create_record() {
  local fields_json="$1"
  local result
  result=$(lark base +record-upsert \
    --base-token "$BASE_TOKEN" \
    --table-id "$TABLE_ID" \
    --json "$fields_json" 2>/dev/null)
  echo "$result" | jq -r '.data.record.record_id_list[0] // empty' 2>/dev/null
}

# 下载消息中的图片
download_image() {
  local msg_id="$1" file_key="$2" output_path="$3"
  # lark-cli 要求相对路径
  local rel_path="${output_path#$SCRIPT_DIR/}"
  lark im +messages-resources-download \
    --message-id "$msg_id" --file-key "$file_key" --type image \
    --output "$rel_path" --as bot >/dev/null 2>&1
  [[ -f "$output_path" && -s "$output_path" ]]
}

# 上传图片到多维表格记录的附件字段
upload_attachment() {
  local record_id="$1" img_path="$2"
  # 如果没有配置附件字段 ID，自动查找
  if [[ -z "$ATTACHMENT_FIELD_ID" ]]; then
    ATTACHMENT_FIELD_ID=$(lark base +field-list \
      --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" 2>/dev/null \
      | jq -r '[.data.fields[] | select(.type == "attachment")][0].field_id // empty')
    [[ -n "$ATTACHMENT_FIELD_ID" ]] && log "自动检测到附件字段: $ATTACHMENT_FIELD_ID"
  fi
  [[ -z "$ATTACHMENT_FIELD_ID" ]] && { log "未找到附件字段，跳过图片上传"; return 1; }
  local rel_path="${img_path#$SCRIPT_DIR/}"
  lark base +record-upload-attachment \
    --base-token "$BASE_TOKEN" \
    --table-id "$TABLE_ID" \
    --record-id "$record_id" \
    --field-id "$ATTACHMENT_FIELD_ID" \
    --file "$rel_path" >/dev/null 2>&1
}

# 拉取聊天历史消息
list_chat_messages() {
  local chat_id="$1" start_ts="$2"
  lark im +chat-messages-list \
    --chat-id "$chat_id" \
    --start "$(date -r "$start_ts" '+%Y-%m-%dT%H:%M:%S'+08:00)" \
    --sort asc \
    --page-size 50 \
    --as bot 2>/dev/null
}

# 列出机器人所在聊天
list_chats() {
  lark im chats list --as bot 2>/dev/null
}

# ===== 业务逻辑 =====

do_query() {
  local item="$1"
  local result
  result=$(fetch_records)

  local fields
  fields=$(echo "$result" | jq -r '.data.fields')
  local item_idx loc_idx qty_idx owner_idx
  item_idx=$(echo "$fields" | jq -r 'index("物品名称")')
  loc_idx=$(echo "$fields" | jq -r 'index("位置")')
  qty_idx=$(echo "$fields" | jq -r 'index("数量")')
  owner_idx=$(echo "$fields" | jq -r 'index("存放人")')

  local matches
  matches=$(echo "$result" | jq -r --arg item "$item" --argjson ii "$item_idx" --argjson li "$loc_idx" --argjson qi "$qty_idx" --argjson oi "$owner_idx" '
    .data.data // [] | map(select(.[$ii] | tostring | ascii_downcase | contains($item | ascii_downcase))) |
    map({item: .[$ii], location: .[$li], quantity: .[$qi], owner: .[$oi]})
  ')

  local count
  count=$(echo "$matches" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    echo "还没收录「${item}」的位置信息哦，要现在记录吗？告诉我放在哪就行~"
  else
    local detail
    detail=$(echo "$matches" | jq -r '.[] | "📦 \(.item)（\(.quantity)个）在 \(.location)\(if .owner then "，存放人：\(.owner)" else "" end)"')
    echo -e "找到了！\n${detail}"
  fi
}

do_list() {
  local result
  result=$(fetch_records)

  local fields
  fields=$(echo "$result" | jq -r '.data.fields')
  local item_idx loc_idx cat_idx
  item_idx=$(echo "$fields" | jq -r 'index("物品名称")')
  loc_idx=$(echo "$fields" | jq -r 'index("位置")')
  cat_idx=$(echo "$fields" | jq -r 'index("分类")')

  local total
  total=$(echo "$result" | jq -r '.data.data | length')

  if [[ "$total" -eq 0 ]]; then
    echo "还没有存入任何物品哦，快告诉我家里东西都放在哪吧~"
    return
  fi

  local reply
  reply=$(echo "$result" | jq -r --argjson ii "$item_idx" --argjson li "$loc_idx" --argjson ci "$cat_idx" '
    .data.data | to_entries[] | "\((.key + 1)). \(.value[$ii]) ｜ \(.value[$ci][0] // "其他") ｜ \(.value[$li])"
  ')

  echo -e "📋 物品清单（共${total}件）\n\n${reply}"
}

do_store() {
  local item="$1" location="$2" category="${3:-其他}" quantity="${4:-1}" note="${5:-}"

  # 构建字段 JSON
  local fields
  fields=$(jq -n \
    --arg item "$item" \
    --arg location "$location" \
    --arg category "$category" \
    --argjson quantity "$quantity" \
    --arg note "$note" \
    '{"物品名称":$item,"位置":$location,"分类":$category,"数量":$quantity}' | \
    jq 'with_entries(select(.value != null))')

  if [[ -n "$note" ]]; then
    fields=$(echo "$fields" | jq --arg note "$note" '. + {"备注":$note}')
  fi

  local rid
  rid=$(create_record "$fields")

  if [[ -n "$rid" ]]; then
    echo "$rid" > "$DATA_DIR/last_record_id"
  fi

  echo "✅ 「${item}」已存入「${location}」"
}

# ===== 消息处理 =====

process_message() {
  local content="$1" chat_id="$2" msg_id="$3" sender_id="${4:-}" is_catchup="${5:-false}"

  [[ -z "$content" ]] && return 1

  # 去重
  local dedup_file="$DATA_DIR/dedup_${msg_id}"
  [[ -f "$dedup_file" ]] && return 1
  touch "$dedup_file"

  remember_chat "$chat_id"

  local prefix=""
  [[ "$is_catchup" == "true" ]] && prefix="[补课] "

  log "${prefix}处理消息: $content"

  # 构造带上下文的用户消息（图片待确认时提示 LLM 优先识别为 store）
  local llm_input="$content"
  local pending_img="$DATA_DIR/pending_image_${chat_id}"
  if [[ -f "$pending_img" ]]; then
    llm_input="[用户刚才发了一张物品图片，现在补充说明] $content"
  fi

  # 调用智谱 API
  local llm_output
  llm_output=$(ask_llm "$llm_input")

  if [[ -z "$llm_output" ]]; then
    [[ "$is_catchup" == "true" ]] && return 0
    send_reply "$chat_id" "抱歉，暂时无法处理，稍后再试~"
    return 0
  fi

  # 清理 markdown 代码块标记
  llm_output=$(echo "$llm_output" | sed 's/^```json//;s/^```//;s/```$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  log "${prefix}LLM 输出: $llm_output"

  local action
  action=$(echo "$llm_output" | jq -r '.action // "chat"' 2>/dev/null || echo "chat")
  local reply=""

  case "$action" in
    store)
      local item location category quantity note
      item=$(echo "$llm_output" | jq -r '.item // empty')
      location=$(echo "$llm_output" | jq -r '.location // empty')
      category=$(echo "$llm_output" | jq -r '.category // "其他"')
      quantity=$(echo "$llm_output" | jq -r '.quantity // 1')
      note=$(echo "$llm_output" | jq -r '.note // ""')

      if [[ -n "$item" && -n "$location" ]]; then
        reply=$(do_store "$item" "$location" "$category" "$quantity" "$note")

        # 检查是否有待上传的图片
        local pending_img="$DATA_DIR/pending_image_${chat_id}"
        if [[ -f "$pending_img" && -f "$DATA_DIR/last_record_id" ]]; then
          local record_id
          record_id=$(cat "$DATA_DIR/last_record_id")
          local img_path
          img_path=$(jq -r '.image_path // empty' "$pending_img" 2>/dev/null)
          if [[ -n "$img_path" && -f "$img_path" && -n "$record_id" ]]; then
            log "上传图片到记录 $record_id"
            if upload_attachment "$record_id" "$img_path"; then
              reply="${reply}"$'\n'"📷 图片已关联"
            else
              log "图片上传失败"
              reply="${reply}"$'\n'"⚠️ 图片关联失败，但物品信息已保存"
            fi
            rm -f "$img_path"
          fi
          rm -f "$pending_img" "$DATA_DIR/last_record_id"
        fi
      else
        reply="物品名或位置信息不完整，请告诉我："$'\n'"1. 什么东西"$'\n'"2. 放在哪里"$'\n'"例如：「把充电器放在书桌第二个抽屉」"
      fi
      ;;
    query)
      local item
      item=$(echo "$llm_output" | jq -r '.item // empty')
      [[ -n "$item" ]] && reply=$(do_query "$item") || reply="你想找什么呢？告诉我物品名称~"
      ;;
    list)
      reply=$(do_list)
      ;;
    suggest)
      reply=$(echo "$llm_output" | jq -r '.reply // "建议放在常用、易取的位置~"')
      ;;
    chat|*)
      reply=$(echo "$llm_output" | jq -r '.reply // "你好！我是家庭收纳助手，你可以告诉我：\n1. 把什么东西放在哪里（存储）\n2. 某个东西在哪（查询）\n3. 看看家里都存了什么（清单）"')
      ;;
  esac

  # 补课模式下，聊天类消息不回复
  if [[ "$is_catchup" == "true" && "$action" == "chat" ]]; then
    log "[补课] 跳过聊天消息，不回复"
    return 0
  fi

  log "${prefix}回复: $reply"
  send_reply "$chat_id" "$reply"
}

# ===== 补课：拉取离线期间的未处理消息 =====
catchup() {
  log "--- 开始补课：检查离线期间的消息 ---"

  local chat_count=0
  chat_count=$(wc -l < "$CHATS_FILE" | tr -d ' ')

  if [[ "$chat_count" -eq 0 ]]; then
    log "没有已知的聊天，跳过补课"
    return
  fi

  while IFS= read -r chat_id; do
    [[ -z "$chat_id" ]] && continue
    log "[补课] 检查聊天: $chat_id"

    local msgs
    msgs=$(lark im +chat-messages-list \
      --chat-id "$chat_id" \
      --start "$(date -v-24H '+%Y-%m-%dT%H:%M:%S'+08:00)" \
      --sort asc \
      --page-size 50 \
      --as bot 2>/dev/null) || continue

    local msg_count=0
    msg_count=$(echo "$msgs" | jq -r '.data.messages // [] | length')

    if [[ "$msg_count" -eq 0 ]]; then
      log "[补课] 聊天 $chat_id 无新消息"
      continue
    fi

    local caught_up=0
    for i in $(seq 0 $((msg_count - 1))); do
      local msg_id msg_type sender_type
      msg_id=$(echo "$msgs" | jq -r ".data.messages[$i].message_id // empty")
      msg_type=$(echo "$msgs" | jq -r ".data.messages[$i].msg_type // empty")
      sender_type=$(echo "$msgs" | jq -r ".data.messages[$i].sender.sender_type // empty")

      [[ "$sender_type" != "user" ]] && continue
      [[ "$msg_type" != "text" ]] && continue
      [[ -f "$DATA_DIR/dedup_${msg_id}" ]] && continue

      local content
      content=$(echo "$msgs" | jq -r ".data.messages[$i].content // empty")

      [[ -z "$content" ]] && continue

      process_message "$content" "$chat_id" "$msg_id" "" "true"
      caught_up=$((caught_up + 1))
    done

    log "[补课] 聊天 $chat_id: 处理了 ${caught_up} 条离线消息"
  done < "$CHATS_FILE"

  log "--- 补课完成 ---"
}

# ===== 轮询：发现新聊天 =====
discover_chats() {
  lark im chats list --as bot 2>/dev/null | \
    jq -r '.chats[]?.chat_id // empty' 2>/dev/null | while IFS= read -r cid; do
    remember_chat "$cid"
  done
}

# ===== 轮询：检查单个聊天的新消息 =====
poll_chat() {
  local chat_id="$1" since_ts="$2"
  local msgs
  msgs=$(lark im +chat-messages-list \
    --chat-id "$chat_id" \
    --start "$(date -r "$since_ts" '+%Y-%m-%dT%H:%M:%S'+08:00)" \
    --sort asc \
    --page-size 10 \
    --as bot 2>/dev/null) || return

  local msg_count=0
  msg_count=$(echo "$msgs" | jq -r '.data.messages // [] | length')
  [[ "$msg_count" -eq 0 ]] && return

  for i in $(seq 0 $((msg_count - 1))); do
    local msg_id msg_type sender_type
    msg_id=$(echo "$msgs" | jq -r ".data.messages[$i].message_id // empty")
    msg_type=$(echo "$msgs" | jq -r ".data.messages[$i].msg_type // empty")
    sender_type=$(echo "$msgs" | jq -r ".data.messages[$i].sender.sender_type // empty")

    [[ "$sender_type" != "user" ]] && continue
    [[ -f "$DATA_DIR/dedup_${msg_id}" ]] && continue

    # 图片消息
    if [[ "$msg_type" == "image" ]]; then
      touch "$DATA_DIR/dedup_${msg_id}"
      remember_chat "$chat_id"

      local content image_key
      content=$(echo "$msgs" | jq -r ".data.messages[$i].content // empty")
      image_key=$(echo "$content" | grep -oE 'img_v[0-9]_[a-zA-Z0-9_-]+' | head -1)
      if [[ -z "$image_key" ]]; then
        image_key=$(echo "$content" | jq -r '.image_key // empty' 2>/dev/null)
      fi

      if [[ -n "$image_key" ]]; then
        mkdir -p "$DATA_DIR/images"
        local_img="$DATA_DIR/images/${msg_id}.jpg"
        if download_image "$msg_id" "$image_key" "$local_img"; then
          echo "{\"image_path\":\"$local_img\",\"message_id\":\"$msg_id\"}" > "$DATA_DIR/pending_image_${chat_id}"
          log "图片已下载，等待物品信息"
          send_reply "$chat_id" "收到图片！请告诉我：这是什么物品，放在哪里？"
        else
          log "图片下载失败"
          send_reply "$chat_id" "图片下载失败，请直接文字告诉我物品名和位置吧~"
        fi
      fi
      continue
    fi

    # 文本消息
    [[ "$msg_type" != "text" ]] && continue
    local content
    content=$(echo "$msgs" | jq -r ".data.messages[$i].content // empty")
    [[ -z "$content" ]] && continue

    process_message "$content" "$chat_id" "$msg_id" "" "false"
  done
}

# ===== 启动 =====

# 清理 48 小时前的去重文件
find "$DATA_DIR" -name 'dedup_*' -mmin +2880 -delete 2>/dev/null || true
# 清理超时（5分钟）的待处理图片
find "$DATA_DIR" -name 'pending_image_*' -mmin +5 -delete 2>/dev/null || true

log "=== 家庭收纳助手启动 (模型: $LLM_MODEL) ==="

catchup

log "轮询模式启动（每 3 秒检查新消息）..."

discover_chats

POLL_INTERVAL=3
while true; do
  now_ts=$(date +%s)
  since_ts=$((now_ts - POLL_INTERVAL - 2))

  while IFS= read -r chat_id; do
    [[ -z "$chat_id" ]] && continue
    poll_chat "$chat_id" "$since_ts"
  done < "$CHATS_FILE"

  sleep "$POLL_INTERVAL"
done
