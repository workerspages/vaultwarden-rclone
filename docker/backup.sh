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

send_telegram_message() {
  local text="$1"
  local type="$2"
  if [[ "${TELEGRAM_ENABLED}" != "true" || -z "${TELEGRAM_BOT_TOKEN}" || -z "${TELEGRAM_CHAT_ID}" ]]; then
    echo "⚠️ Telegram 未启用或未配置。"
    return 1
  fi
  local json_data="{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${text}\",\"disable_web_page_preview\":true}"
  local response
  response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$json_data")
  echo "API响应 $type: $response"
  if echo "$response" | grep -q '"ok":true'; then
    echo "✅ $type 通知已发出"
    return 0
  else
    echo "❌ $type 通知失败，检查TOKEN/CHAT_ID/容器网络"
    return 1
  fi
}

send_telegram_error() {
  local error_msg="$1"
  local timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  local msg="🚨 Vaultwarden 备份失败

❌ 错误详情: $error_msg

⏰ 发生时间: $timestamp

💡 修复建议: 检查 RCLONE_REMOTE 配置或联系管理员！"
  send_telegram_message "$msg" "失败"
}

send_telegram_success() {
  local archive_size="$1"
  local timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  local msg="✅ Vaultwarden 备份成功

📦 文件大小: $archive_size

📅 完成时间: $timestamp

☁️ 存储位置: $RCLONE_REMOTE

🧹 清理: 保留 $BACKUP_RETAIN_DAYS 天"
  send_telegram_message "$msg" "成功"
}

if [[ "${TEST_MODE}" == "true" ]]; then
  echo "🧪 TEST_MODE: 基础curl发一条测试消息"
  local resp
  resp=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"🧪 测试: $(date)\",\"disable_web_page_preview\":true}")
  echo "手动消息响应: $resp"
  if echo "$resp" | grep -q '"ok":true'; then
    send_telegram_error "Test error with special chars: * & < > \" '"
    send_telegram_success "10.5 MB"
  else
    echo "❌ 手动curl测试失败，上 Telegram 查bot对话/频道权限、TOKEN、网络"
  fi
  exit 0
fi

if [[ -z "${RCLONE_REMOTE}" ]]; then
  send_telegram_error "RCLONE_REMOTE 未设置，跳过备份。"
  exit 0
fi

ts="$(date -u +%Y%m%d-%H%M%S)"
tmp_dir="$(mktemp -d)"
archive="$tmp_dir/${BACKUP_FILENAME_PREFIX}-${ts}.tar.${BACKUP_COMPRESSION}"
error_msg=""

cd "${BACKUP_SRC}"

echo "🔄 创建备份归档..."
case "${BACKUP_COMPRESSION}" in
  gz)  tar -czf "${archive}" . ;;
  zst) tar -I 'zstd -19 -T0' -cf "${archive}" . ;;
  bz2) tar -cjf "${archive}" . ;;
  xz)  tar -cJf "${archive}" . ;;
  *)   echo "❌ 不支持压缩: ${BACKUP_COMPRESSION}"; exit 2 ;;
esac

archive_size=$(du -h "${archive}" | cut -f1)
echo "✅ 备份归档: $archive_size"

echo "📤 上传到 $RCLONE_REMOTE ..."
if ! rclone copy "${archive}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS}; then
  error_msg="上传失败（网络或存储问题）。"
else
  echo "✅ 上传成功"
fi

cleanup_error=""
if [[ -z "$error_msg" && "${BACKUP_RETAIN_DAYS}" -gt 0 ]]; then
  echo "🧹 清理: 删除超过 ${BACKUP_RETAIN_DAYS} 天的备份..."
  if [[ "${CLEANUP_METHOD}" == "min-age" ]]; then
    if rclone delete "${RCLONE_REMOTE}" --min-age "${BACKUP_RETAIN_DAYS}d" --include "*.tar.*" -v | tee /tmp/rclone_delete.log; then
      echo "✅ 清理完成"
    else
      echo "⚠️ rclone --min-age清理失败，尝试jq"
      CLEANUP_METHOD="jq"
    fi
  fi
  if [[ "${CLEANUP_METHOD}" == "jq" ]]; then
    echo "🔧 使用jq清理（WebDAV兼容）..."
    if command -v jq >/dev/null 2>&1; then
      cutoff_date=$(date -d "${BACKUP_RETAIN_DAYS} days ago" '+%Y%m%d')
      if rclone lsjson "${RCLONE_REMOTE}" --files-only 2>/dev/null | jq -r ".[] | select(.Path | test(\"${BACKUP_FILENAME_PREFIX}.*\\\\.tar\\\\.${BACKUP_COMPRESSION}\$\")) | .Path" | while read -r file; do
        file_date=$(echo "$file" | grep -oE "[0-9]{8}" | head -1)
        if [[ -n "$file_date" && "$file_date" -lt "$cutoff_date" ]]; then
          echo "  🗑️ 删除: $file"
          rclone delete "${RCLONE_REMOTE}/${file}" 2>/dev/null || true
        fi
      done; then
        echo "✅ jq清理完成"
      else
        cleanup_error="jq清理失败"
      fi
    else
      cleanup_error="未找到jq。设置BACKUP_RETAIN_DAYS=0可禁用清理。"
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
