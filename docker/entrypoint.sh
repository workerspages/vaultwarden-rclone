#!/bin/sh
set -euo pipefail

# 加载 rclone 配置（始终执行）
if [[ -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# 停止任何现有 Vaultwarden 进程（Zeabur 可能有初始启动）
sleep 5  # 延迟等待卷挂载
pkill -f vaultwarden || killall vaultwarden || true
sleep 2

# 支持启动命令：如果参数为 "restore latest"，执行还原
if [[ "${1:-}" == "restore" && "${2:-}" == "latest" ]]; then
  echo "🧩 启动命令模式：执行还原 ${2}"
  /usr/local/bin/restore.sh "${2}" || {
    echo "⚠️ 还原失败（可能无备份），继续启动服务"
    # Telegram 错误通知已在 restore.sh 内处理
  }
  echo "✅ 还原完成，继续启动 Vaultwarden"
  shift 2  # 移除参数，继续 exec
fi

# 启动备份调度（如果启用）
if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
  echo "📅 启动备份调度：${BACKUP_CRON:-0 3 * * *}"
  supercronic -f -m default -q "${BACKUP_CRON:-0 3 * * *}" /usr/local/bin/backup.sh &
fi

# 启动 Vaultwarden（exec 替换当前进程为 PID 1）
exec /vaultwarden server "$@"  # 或原 CMD：exec vaultwarden "$@"
