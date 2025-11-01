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
: "${TELEGRAM_MESSAGE:=🚨 *Vaultwarden 备份失败*\\n*错误详情：* %ERROR%\\n*时间戳：* %TIME%\\n*建议：* 验证 RCLONE_REMOTE 配置或联系管理员。}"

# MarkdownV2 转义函数（处理特殊字符）
escape_markdown_v2() {
  local text="$1"
  # 转义 MarkdownV2 特殊字符
  text=$(echo "$text" | sed 's/[_*[]()~>#+=|{}.!\\-/\\/g')
  echo "$text"
}

send_telegram() {
  local error_msg="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')  # 生成时间戳
  local message="$TELEGRAM_MESSAGE"
  
  # 替换占位符并转义
  local escaped_error=$(escape_markdown_v2 "$error_msg")
  message="${message//%ERROR%/${escaped_error}}"
  message="${message//%TIME%/${timestamp}}"
  
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${message}\",\"parse_mode\":\"MarkdownV2\"}" >/dev/null || {
        echo "Telegram notification failed (non-fatal)"
      }
  fi
}

if [[ -z "${RCLONE_REMOTE}" ]]; then
  send_telegram "RCLONE_REMOTE is not set; skipping backup."
  exit 0
fi

ts="$(date -u +%Y%m%d-%H%M%S)"
tmp_dir="$(mktemp -d)"
archive="${tmp_dir}/${BACKUP_FILENAME_PREFIX}-${ts}.tar.${BACKUP_COMPRESSION}"
error_msg=""

cd "${BACKUP_SRC}"

case "${BACKUP_COMPRESSION}" in
  gz)  tar -czf "${archive}" . ;;
  zst) tar -I 'zstd -19 -T0' -cf "${archive}" . ;;
  bz2) tar -cjf "${archive}" . ;;
  xz)  tar -cJf "${archive}" . ;;
  *)   echo "Unsupported compression: ${BACKUP_COMPRESSION}"; exit 2 ;;
esac

# 执行上传并检查
if ! rclone copy "${archive}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS}; then
  error_msg="Upload failed (network or storage issue)."
fi

# 过期清理（如果上传成功再清理，捕获清理错误）
cleanup_error=""
if [[ -z "${error_msg}" && "${BACKUP_RETAIN_DAYS}" -gt 0 ]]; then
  if ! rclone delete "${RCLONE_REMOTE}" --min-age "${BACKUP_RETAIN_DAYS}d" --include "*.tar.*"; then
    cleanup_error="Cleanup failed after successful upload. Check RCLONE_REMOTE permissions or cloud storage limits."
  fi
fi

rm -rf "${tmp_dir}"

if [[ -n "${error_msg}" ]]; then
  send_telegram "${error_msg}"
  exit 1
elif [[ -n "${cleanup_error}" ]]; then
  send_telegram "${cleanup_error}"  # 单独处理清理失败（非致命，但通知）
  exit 0  # 清理失败不中断整体备份成功
fi
