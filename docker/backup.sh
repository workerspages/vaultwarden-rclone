#!/usr/bin/env bash
set -euo pipefail

: "${BACKUP_SRC:=/data}"
: "${BACKUP_FILENAME_PREFIX:=vaultwarden}"
: "${BACKUP_COMPRESSION:=gz}"
: "${RCLONE_REMOTE:=}"
: "${RCLONE_FLAGS:=}"
: "${TELEGRAM_ENABLED:=false}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"
: "${TEST_MODE:=false}"
: "${RETENTION_MODE:=smart}"
: "${BACKUP_RETAIN_DAYS:=14}"
: "${BACKUP_RETAIN_COUNT:=30}"
: "${RCLONE_VIEW_URL:=}"

# 自动加载 rclone 配置
if [[ -z "${RCLONE_CONFIG:-}" && -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | tr -d '\n\r ' | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

RCLONE_REMOTE="${RCLONE_REMOTE#0}"

# HTML 转义函数
html_escape() {
  local text="$1"
  echo "$text" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'
}

# Telegram 发送函数
send_telegram_message() {
  local message="$1"
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${message}" \
      -d "parse_mode=HTML" \
      -d "disable_web_page_preview=true" >/dev/null
  fi
}

# 错误通知
send_telegram_error() {
  local error_msg="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local escaped_error=$(html_escape "$error_msg")
  local link_part=""
  if [[ -n "${RCLONE_VIEW_URL}" ]]; then
    link_part="<a href='${RCLONE_VIEW_URL}'>查看云盘</a>"
  fi

  local message
  message=$(printf '%s\n\n%s\n<code>%s</code>\n\n%s\n%s\n\n%s\n%s %s\n' \
    "<b>🚨 Vaultwarden 备份失败</b>" \
    "<b>❌ 错误详情</b>" \
    "$escaped_error" \
    "<b>⏰ 发生时间</b>" \
    "$timestamp" \
    "<b>💡 修复建议</b>" \
    "检查 RCLONE_REMOTE 配置，或" "$link_part 联系管理员。"
  )

  send_telegram_message "$message"
}

# 成功通知
send_telegram_success() {
  local archive_size="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local remote_link="${RCLONE_REMOTE}"
  if [[ -n "${RCLONE_VIEW_URL}" ]]; then
    remote_link=$(printf '<a href="%s">%s</a>' "${RCLONE_VIEW_URL}" "${RCLONE_REMOTE}")
  fi
  
  local policy_desc="未知"
  case "${RETENTION_MODE}" in
    smart) policy_desc="智能策略 (7天/4周/12月)";;
    days)  policy_desc="保留最近 ${BACKUP_RETAIN_DAYS} 天";;
    count) policy_desc="保留最近 ${BACKUP_RETAIN_COUNT} 份";;
    forever) policy_desc="永久保留";;
  esac

  local message
  message=$(printf '%s\n\n%s\n<code>%s</code>\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n' \
    "<b>✅ Vaultwarden 备份成功</b>" \
    "<b>📦 文件大小</b>" \
    "${archive_size}" \
    "<b>📅 完成时间</b>" \
    "${timestamp}" \
    "<b>☁️ 存储位置</b>" \
    "$remote_link" \
    "<b>🧹 清理策略</b>" \
    "${policy_desc}"
  )

  send_telegram_message "$message"
}

# 测试模式
if [[ "${TEST_MODE}" == "true" ]]; then
  send_telegram_error "Test error"
  exit 0
fi

if [[ -z "${RCLONE_REMOTE}" ]]; then
  send_telegram_error "RCLONE_REMOTE 未设置；跳过备份。"
  exit 0
fi

# 备份核心逻辑
ts="$(date -u +%Y%m%d-%H%M%S)"
tmp_dir="$(mktemp -d)"
archive="${tmp_dir}/${BACKUP_FILENAME_PREFIX}-${ts}.tar.${BACKUP_COMPRESSION}"
error_msg=""

cd "${BACKUP_SRC}"

echo "📦 Creating archive: ${archive} ..."
case "${BACKUP_COMPRESSION}" in
  gz)  tar -czf "${archive}" . ;;
  zst) tar -I 'zstd -19 -T0' -cf "${archive}" . ;;
  bz2) tar -cjf "${archive}" . ;;
  xz)  tar -cJf "${archive}" . ;;
  *)   send_telegram_error "不支持压缩: ${BACKUP_COMPRESSION}"; exit 2 ;;
esac

archive_size=$(du -h "${archive}" | cut -f1)

echo "☁️ Uploading to ${RCLONE_REMOTE} ..."
if ! rclone copy "${archive}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS}; then
  error_msg="上传失败（网络或存储问题）。"
fi

# 如果上传本身失败了，直接报错退出
if [[ -n "${error_msg}" ]]; then
  send_telegram_error "${error_msg}"
  rm -rf "${tmp_dir}"
  exit 1
fi

# --- 只有上传成功了才执行清理 ---
echo "🧹 Running cleanup strategy: ${RETENTION_MODE}..."
export RCLONE_REMOTE
export BACKUP_FILENAME_PREFIX
export RETENTION_MODE
export BACKUP_RETAIN_DAYS
export BACKUP_RETAIN_COUNT

# 执行清理，无论成功与否，都不影响“备份成功”的状态
# 将 stderr 重定向到 stdout，防止被误判为严重错误
if python3 /docker/retention.py > /tmp/retention.log 2>&1; then
  cat /tmp/retention.log
  echo "✅ Cleanup finished."
else
  echo "⚠️ Cleanup script warning (check logs):"
  cat /tmp/retention.log
  # 这里不设置 error_msg，不发送失败通知
fi

rm -rf "${tmp_dir}"

# 发送成功通知
send_telegram_success "${archive_size}"
