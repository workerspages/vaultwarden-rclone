#!/usr/bin/env bash
set -euo pipefail

: "${BACKUP_SRC:=/data}"
: "${BACKUP_FILENAME_PREFIX:=vaultwarden}"
: "${BACKUP_COMPRESSION:=gz}"
: "${RCLONE_REMOTE:=}"
: "${RCLONE_FLAGS:=}"
: "${BACKUP_RETAIN_DAYS:=14}"
: "${TELEGRAM_ENABLED:=false}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"
: "${TEST_MODE:=false}"
: "${CLEANUP_METHOD:=min-age}"

# 自动加载 rclone 配置
if [[ -z "${RCLONE_CONFIG:-}" && -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# 清理 RCLONE_REMOTE 中的前缀（如 PaaS 自动添加）
RCLONE_REMOTE="${RCLONE_REMOTE#0}"

# Telegram 失败通知（美化排版版本）
send_telegram_error() {
  local error_msg="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  
  # 使用 printf 处理换行和格式
  local message
  message=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
    '<b>🚨 Vaultwarden 备份失败</b>' \
    '' \
    '<b>❌ 错误详情：</b>' \
    "<code>${error_msg}</code>" \
    '' \
    '<b>⏰ 时间戳：</b>' \
    "${timestamp}" \
    '' \
    '<b>💡 建议：</b>' \
    '验证 RCLONE_REMOTE 配置或联系管理员。')
  
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    echo "📤 Sending error notification to Telegram..."
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"$(echo "$message" | jq -Rs .)\",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}" >/dev/null || {
        echo "⚠️  Telegram notification failed (non-fatal)"
      }
  fi
}

# Telegram 成功通知（美化排版版本）
send_telegram_success() {
  local archive_size="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  
  local message
  message=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
    '<b>✅ Vaultwarden 备份成功</b>' \
    '' \
    '<b>📦 备份大小：</b>' \
    "${archive_size}" \
    '<b>📅 完成时间：</b>' \
    "${timestamp}" \
    '<b>☁️ 目标位置：</b>' \
    "${RCLONE_REMOTE}")
  
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    echo "📤 Sending success notification to Telegram..."
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"$(echo "$message" | jq -Rs .)\",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}" >/dev/null || {
        echo "⚠️  Telegram notification failed (non-fatal)"
      }
  fi
}

# 测试模式
if [[ "${TEST_MODE}" == "true" ]]; then
  echo "🧪 Test mode: Sending sample notifications..."
  send_telegram_error "Test error with special chars: * & < > \" '"
  send_telegram_success "10.5 MB"
  exit 0
fi

# 检查 RCLONE_REMOTE
if [[ -z "${RCLONE_REMOTE}" ]]; then
  send_telegram_error "RCLONE_REMOTE is not set; skipping backup."
  exit 0
fi

# 创建备份
ts="$(date -u +%Y%m%d-%H%M%S)"
tmp_dir="$(mktemp -d)"
archive="${tmp_dir}/${BACKUP_FILENAME_PREFIX}-${ts}.tar.${BACKUP_COMPRESSION}"
error_msg=""

cd "${BACKUP_SRC}"

echo "🔄 Creating backup archive..."
case "${BACKUP_COMPRESSION}" in
  gz)  tar -czf "${archive}" . ;;
  zst) tar -I 'zstd -19 -T0' -cf "${archive}" . ;;
  bz2) tar -cjf "${archive}" . ;;
  xz)  tar -cJf "${archive}" . ;;
  *)   echo "❌ Unsupported compression: ${BACKUP_COMPRESSION}"; exit 2 ;;
esac

archive_size=$(du -h "${archive}" | cut -f1)
echo "✅ Backup archive created: ${archive_size}"

# 上传备份
echo "📤 Uploading to ${RCLONE_REMOTE}..."
if ! rclone copy "${archive}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS}; then
  error_msg="Upload failed (network or storage issue)."
else
  echo "✅ Upload completed successfully"
fi

# 清理旧备份
cleanup_error=""
if [[ -z "${error_msg}" && "${BACKUP_RETAIN_DAYS}" -gt 0 ]]; then
  echo "🧹 Cleanup: Deleting files older than ${BACKUP_RETAIN_DAYS} days..."
  
  if [[ "${CLEANUP_METHOD}" == "min-age" ]]; then
    if rclone delete "${RCLONE_REMOTE}" --min-age "${BACKUP_RETAIN_DAYS}d" --include "*.tar.*" -v 2>&1 | tee /tmp/rclone_delete.log; then
      echo "✅ Cleanup completed successfully"
    else
      echo "⚠️  rclone --min-age failed. Attempting jq-based cleanup..."
      CLEANUP_METHOD="jq"
    fi
  fi
  
  if [[ "${CLEANUP_METHOD}" == "jq" ]]; then
    echo "🔧 Using jq-based cleanup (WebDAV compatible)..."
    if command -v jq >/dev/null 2>&1; then
      cutoff_date=$(date -d "${BACKUP_RETAIN_DAYS} days ago" '+%Y%m%d')
      deleted_count=0
      
      if rclone lsjson "${RCLONE_REMOTE}" --files-only 2>/dev/null | jq -r ".[] | select(.Path | test(\"${BACKUP_FILENAME_PREFIX}.*\\\\.tar\\\\.${BACKUP_COMPRESSION}\$\")) | .Path" | while read -r file; do
        file_date=$(echo "$file" | grep -oE "[0-9]{8}" | head -1)
        if [[ -n "$file_date" && "$file_date" -lt "$cutoff_date" ]]; then
          echo "  🗑️  Deleting: $file"
          if rclone delete "${RCLONE_REMOTE}/${file}" 2>/dev/null; then
            ((deleted_count++))
          fi
        fi
      done; then
        echo "✅ jq-based cleanup completed"
      else
        cleanup_error="jq-based cleanup failed. Check jq availability or rclone access."
      fi
    else
      cleanup_error="jq not found. Install jq or disable cleanup by setting BACKUP_RETAIN_DAYS=0."
    fi
  fi
fi

# 清理临时目录
rm -rf "${tmp_dir}"

# 处理结果
if [[ -n "${error_msg}" ]]; then
  send_telegram_error "${error_msg}"
  exit 1
elif [[ -n "${cleanup_error}" ]]; then
  send_telegram_error "${cleanup_error}"
  exit 0
fi

# 成功完成
echo "✨ Backup completed successfully"
send_telegram_success "${archive_size}"
