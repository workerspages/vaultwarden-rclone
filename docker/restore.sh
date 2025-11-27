#!/usr/bin/env bash
set -euo pipefail

: "${BACKUP_SRC:=/data}"
: "${RESTORE_STRATEGY:=replace}"
: "${TELEGRAM_ENABLED:=false}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"
: "${RCLONE_REMOTE:=}"

# 自动加载 rclone 配置 (同前)
if [[ -z "${RCLONE_CONFIG:-}" && -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# Telegram 通知函数 (同前)
send_telegram_message() {
  local message="$1" local type="$2"
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${message}" \
      -d "parse_mode=HTML" >/dev/null
  fi
}

send_restore_success() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local message=$(printf '<b>✅ Vaultwarden 数据还原成功</b>\n\n<b>📅 完成时间</b>\n%s\n\n<b>💾 源文件</b>\n<code>%s</code>' \
    "${timestamp}" "${remote_obj}")
  send_telegram_message "$message" "成功"
}

send_restore_error() {
  local error_msg="$1" local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local escaped_error=$(echo "$error_msg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
  local message=$(printf '<b>🚨 Vaultwarden 数据还原失败</b>\n\n<b>❌ 错误详情</b>\n<code>%s</code>\n\n<b>⏰ 发生时间</b>\n%s' \
    "$escaped_error" "${timestamp}")
  send_telegram_message "$message" "错误"
}

mode="${1:-}"
if [[ -z "${mode}" ]]; then
  echo "Usage: restore.sh latest | <remote-object-filename> | <local-file-path>"
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

local_archive=""
remote_obj="${mode}"

# --- 新增逻辑：检查是否为本地文件 ---
if [[ -f "${mode}" ]]; then
  echo "📂 Detected local file input: ${mode}"
  local_archive="${mode}"
  # 验证是否为压缩包 (简单的后缀检查，防止误传)
  if [[ ! "${mode}" =~ \.(tar|gz|zst|bz2|xz|zip)$ ]]; then
    send_restore_error "Invalid file format uploaded"
    exit 1
  fi
else
  # 原有逻辑：从 Rclone 下载
  fetch_latest() {
    if ! rclone lsjson "${RCLONE_REMOTE}" --files-only --fast-list >"${work}/ls.json" 2>/dev/null; then
      send_restore_error "Failed to list remote files in ${RCLONE_REMOTE}"
      exit 1
    fi
    jq -r 'sort_by(.ModTime)|last? | .Path // empty' <"${work}/ls.json"
  }

  if [[ "${mode}" == "latest" ]]; then
    if [[ -z "${RCLONE_REMOTE}" ]]; then
      send_restore_error "RCLONE_REMOTE is not set for latest mode"
      exit 1
    fi
    remote_obj="$(fetch_latest)"
  fi

  if [[ -z "${remote_obj}" ]]; then
    send_restore_error "No remote object to restore"
    exit 1
  fi

  echo "☁️  Downloading from remote: ${remote_obj}"
  local_archive="${work}/restore.tar"
  if ! rclone copyto "${RCLONE_REMOTE%/}/${remote_obj}" "${local_archive}" 2>/dev/null; then
    send_restore_error "Failed to download backup file: ${remote_obj}"
    exit 1
  fi
fi
# --- 逻辑结束 ---

# 备份当前数据
backup_before="${BACKUP_SRC%/}.pre-restore-$(date -u +%Y%m%d-%H%M%S)"
echo "📦 Backing up current data to ${backup_before}..."
if ! cp -a "${BACKUP_SRC}" "${backup_before}"; then
  send_restore_error "Failed to backup existing data"
  exit 1
fi

# 设置错误回滚
trap 'echo "⚠️ Restore failed! Rolling back..."; rm -rf "${BACKUP_SRC}"; mv "${backup_before}" "${BACKUP_SRC}"; rm -rf "${work}"' ERR

if [[ "${RESTORE_STRATEGY}" == "replace" ]]; then
  echo "🧹 Cleaning existing data..."
  find "${BACKUP_SRC}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi

echo "🔓 Extracting archive..."
case "${local_archive}" in
  *.tar.gz|*.tgz)    tar -xzf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.zst|*.tzst)  tar -I zstd -xf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.bz2|*.tbz2)  tar -xjf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.xz|*.txz)    tar -xJf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar)             tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.zip)             unzip -o "${local_archive}" -d "${BACKUP_SRC}" ;; # 增加 zip 支持以防万一
  *)                 tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
esac

# 成功后移除 trap 中的回滚逻辑，只保留 cleanup
trap 'rm -rf "${work}"' EXIT

echo "✅ Restore done. Previous data saved at: ${backup_before}"
send_restore_success
