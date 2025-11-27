#!/usr/bin/env bash
set -euo pipefail

# --- 加载持久化配置 (新路径) ---
if [[ -f "/conf/env.conf" ]]; then
    set -a
    source "/conf/env.conf"
    set +a
fi

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

if [[ -z "${RCLONE_CONFIG:-}" && -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | tr -d '\n\r ' | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

RCLONE_REMOTE="${RCLONE_REMOTE#0}"

# HTML 转义
html_escape() {
  local text="$1"
  echo "$text" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'
}

# Telegram 发送
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
  local message=$(printf '%s\n\n%s\n<code>%s</code>\n\n%s\n%s\n' \
    "<b>🚨 Vaultwarden 备份失败</b>" "<b>❌ 错误</b>" "$escaped_error" "<b>⏰ 时间</b>" "$timestamp")
  send_telegram_message "$message"
}

# 成功通知
send_telegram_success() {
  local archive_size="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local remote_link="${RCLONE_REMOTE}"
  local message=$(printf '%s\n\n%s\n<code>%s</code>\n\n%s\n%s\n\n%s\n%s\n' \
    "<b>✅ Vaultwarden 备份成功</b>" "<b>📦 大小</b>" "${archive_size}" "<b>📅 时间</b>" "${timestamp}" "<b>☁️ 位置</b>" "$remote_link")
  send_telegram_message "$message"
}

if [[ -z "${RCLONE_REMOTE}" ]]; then
  send_telegram_error "RCLONE_REMOTE 未设置"
  exit 0
fi

# 备份逻辑：直接打包 /data，无需排除
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
  error_msg="上传失败"
fi

if [[ -n "${error_msg}" ]]; then
  send_telegram_error "${error_msg}"
  rm -rf "${tmp_dir}"
  exit 1
fi

# 清理逻辑
echo "🧹 Running cleanup strategy..."
export RCLONE_REMOTE BACKUP_FILENAME_PREFIX RETENTION_MODE BACKUP_RETAIN_DAYS BACKUP_RETAIN_COUNT
if python3 /app/dashboard/retention.py > /tmp/retention.log 2>&1; then
  cat /tmp/retention.log
  echo "✅ Cleanup finished."
else
  echo "⚠️ Cleanup warning:"
  cat /tmp/retention.log
fi

rm -rf "${tmp_dir}"
send_telegram_success "${archive_size}"
