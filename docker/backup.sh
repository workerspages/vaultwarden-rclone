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

# Telegram 失败通知（用 printf 确保 \n 换行，无多行错误）
send_telegram_error() {
  local error_msg="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  
  local message
  message=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "<b>🚨 Vaultwarden 备份失败</b>" \
    "" \
    "<b>❌ 错误详情</b>" \
    "<code>${error_msg}</code>" \
    "" \
    "<b>⏰ 发生时间</b>" \
    "${timestamp}" \
    "<b>💡 修复建议</b>" \
    "请检查 RCLONE_REMOTE 配置，或联系管理员手动验证。"
  )
  
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    echo "📤 发送错误通知到 Telegram..."
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${message}\",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}")
    
    # 可选调试：生产时注释掉
    if [[ "${TEST_MODE}" == "true" ]]; then
      echo "🔍 API 响应: ${response}"
    fi
    
    if echo "$response" | grep -q '"ok":true'; then
      echo "✅ 错误通知发送成功"
    else
      echo "⚠️ 错误通知失败: ${response}"
    fi
  else
    echo "⚠️ Telegram 未启用或缺少凭证"
  fi
}

# Telegram 成功通知（同样用 printf，确保一致性）
send_telegram_success() {
  local archive_size="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  
  local message
  message=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "<b>✅ Vaultwarden 备份成功</b>" \
    "" \
    "<b>📦 文件大小</b>" \
    "<code>${archive_size}</code>" \
    "" \
    "<b>📅 完成时间</b>" \
    "${timestamp}" \
    "<b>☁️ 存储位置</b>" \
    "${RCLONE_REMOTE}" \
    "<b>🧹 清理状态</b>" \
    "旧文件已自动删除（保留 ${BACKUP_RETAIN_DAYS} 天）。"
  )
  
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    echo "📤 发送成功通知到 Telegram..."
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${message}\",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}")
    
    # 可选调试：生产时注释掉
    if [[ "${TEST_MODE}" == "true" ]]; then
      echo "🔍 API 响应: ${response}"
    fi
    
    if echo "$response" | grep -q '"ok":true'; then
      echo "✅ 成功通知发送成功"
    else
      echo "⚠️ 成功通知失败: ${response}"
    fi
  else
    echo "⚠️ Telegram 未启用或缺少凭证"
  fi
}

# 测试模式
if [[ "${TEST_MODE}" == "true" ]]; then
  echo "🧪 测试模式：发送示例通知..."
  send_telegram_error "Test error with special chars: * & < > \" '"
  send_telegram_success "10.5 MB"
  exit 0
fi

# 检查 RCLONE_REMOTE
if [[ -z "${RCLONE_REMOTE}" ]]; then
  send_telegram_error "RCLONE_REMOTE 未设置；跳过备份。"
  exit 0
fi

# 创建备份
ts="$(date -u +%Y%m%d-%H%M%S)"
tmp_dir="$(mktemp -d)"
archive="${tmp_dir}/${BACKUP_FILENAME_PREFIX}-${ts}.tar.${BACKUP_COMPRESSION}"
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
echo "✅ 备份归档创建完成: ${archive_size}"

# 上传备份
echo "📤 上传到 ${RCLONE_REMOTE}..."
if ! rclone copy "${archive}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS}; then
  error_msg="上传失败（网络或存储问题）。"
else
  echo "✅ 上传成功"
fi

# 清理旧备份
cleanup_error=""
if [[ -z "${error_msg}" && "${BACKUP_RETAIN_DAYS}" -gt 0 ]]; then
  echo "🧹 清理：删除超过 ${BACKUP_RETAIN_DAYS} 天的文件..."
  
  if [[ "${CLEANUP_METHOD}" == "min-age" ]]; then
    if rclone delete "${RCLONE_REMOTE}" --min-age "${BACKUP_RETAIN_DAYS}d" --include "*.tar.*" -v 2>&1 | tee /tmp/rclone_delete.log; then
      echo "✅ 清理完成"
    else
      echo "⚠️ rclone --min-age 失败。尝试 jq 清理..."
      CLEANUP_METHOD="jq"
    fi
  fi
  
  if [[ "${CLEANUP_METHOD}" == "jq" ]]; then
    echo "🔧 使用 jq 清理（兼容 WebDAV）..."
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
      cleanup_error="未找到 jq。请设置 BACKUP_RETAIN_DAYS=0 禁用清理。"
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
echo "✨ 备份完成成功"
send_telegram_success "${archive_size}"
