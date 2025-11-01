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

RCLONE_REMOTE="${RCLONE_REMOTE#0}"

send_telegram_error() {
  local error_msg="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local message="<b>🚨 Vaultwarden 备份失败</b>
<b>❌ 错误详情</b>
<code>${error_msg}</code>

<b>⏰ 发生时间</b>
${timestamp}

<b>💡 修复建议</b>
请检查 RCLONE_REMOTE 配置，或联系管理员手动验证。"
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${message}\",\"parse_mode\":\"HTML\"}" >/dev/null
  fi
}

send_telegram_success() {
  local archive_size="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local message="<b>✅ Vaultwarden 备份成功</b>
<b>📦 文件大小</b>
<code>${archive_size}</code>

<b>📅 完成时间</b>
${timestamp}

<b>☁️ 存储位置</b>
${RCLONE_REMOTE}

<b>🧹 清理状态</b>
旧文件已自动删除（保留 ${BACKUP_RETAIN_DAYS} 天）。"
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${message}\",\"parse_mode\":\"HTML\"}" >/dev/null
  fi
}

if [[ "${TEST_MODE}" == "true" ]]; then
  echo "🧪 测试模式：发送 Telegram 消息 ..."
  send_telegram_error "Test error with special chars: * & < > \" '"
  send_telegram_success "10.5 MB"
  exit 0
fi

if [[ -z "${RCLONE_REMOTE}" ]]; then
  send_telegram_error "RCLONE_REMOTE 未设置，跳过备份。"
  exit 0
fi

ts="$(date -u +%Y%m%d-%H%M%S)"
tmp_dir="$(mktemp -d)"
archive="${tmp_dir}/${BACKUP_FILENAME_PREFIX}-${ts}.tar.${BACKUP_COMPRESSION}"
error_msg=""

cd "${BACKUP_SRC}"

echo "🔄 创建备份归档 ..."
case "${BACKUP_COMPRESSION}" in
  gz)  tar -czf "${archive}" . ;;
  zst) tar -I 'zstd -19 -T0' -cf "${archive}" . ;;
  bz2) tar -cjf "${archive}" . ;;
  xz)  tar -cJf "${archive}" . ;;
  *)   echo "❌ 不支持压缩: ${BACKUP_COMPRESSION}"; exit 2 ;;
esac

archive_size=$(du -h "${archive}" | cut -f1)
echo "✅ 备份归档完成: ${archive_size}"

echo "📤 上传到 ${RCLONE_REMOTE} ..."
if ! rclone copy "${archive}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS}; then
  error_msg="Upload failed (network or storage issue)."
else
  echo "✅ 上传成功"
fi

cleanup_error=""
if [[ -z "${error_msg}" && "${BACKUP_RETAIN_DAYS}" -gt 0 ]]; then
  echo "🧹 清理：删除超过 ${BACKUP_RETAIN_DAYS} 天的备份 ..."
  if [[ "${CLEANUP_METHOD}" == "min-age" ]]; then
    if rclone delete "${RCLONE_REMOTE}" --min-age "${BACKUP_RETAIN_DAYS}d" --include "*.tar.*" -v 2>&1 | tee /tmp/rclone_delete.log; then
      echo "✅ 清理完成"
    else
      echo "⚠️ rclone --min-age 清理失败，尝试 jq ..."
      CLEANUP_METHOD="jq"
    fi
  fi
  if [[ "${CLEANUP_METHOD}" == "jq" ]]; then
    if command -v jq >/dev/null 2>&1; then
      cutoff_date=$(date -d "${BACKUP_RETAIN_DAYS} days ago" '+%Y%m%d')
      if rclone lsjson "${RCLONE_REMOTE}" --files-only 2>/dev/null | jq -r ".[] | select(.Path | test(\"${BACKUP_FILENAME_PREFIX}.*\\\\.tar\\\\.${BACKUP_COMPRESSION}\$\")) | .Path" | while read -r file; do
        file_date=$(echo "$file" | grep -oE "[0-9]{8}" | head -1)
        if [[ -n "$file_date" && "$file_date" -lt "$cutoff_date" ]]; then
          echo "  🗑️ 删除: $file"
          rclone delete "${RCLONE_REMOTE}/${file}" 2>/dev/null || true
        fi
      done; then
        echo "✅ jq 清理完成"
      else
        cleanup_error="jq 清理失败"
      fi
    else
      cleanup_error="未找到 jq，建议关闭清理或装 jq"
    fi
  fi
fi

rm -rf "${tmp_dir}"

if [[ -n "${error_msg}" ]]; then
  send_telegram_error "${error_msg}"
  exit 1
elif [[ -n "${cleanup_error}" ]]; then
  send_telegram_error "${cleanup_error}"
  exit 0
fi

echo "✨ 备份完成"
send_telegram_success "${archive_size}"
