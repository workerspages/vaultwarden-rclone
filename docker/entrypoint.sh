#!/usr/bin/env bash
set -e

# 启动 Vaultwarden 服务（后台）
echo "🚀 Starting Vaultwarden service..."
exec_path="/start.sh"

# 如果启用备份，创建并启动定时任务
if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
  echo "📅 Configuring backup schedule: ${BACKUP_CRON}"
  
  # 创建临时 crontab 文件（supercronic 需要）
  CRONTAB_FILE="/tmp/crontab"
  cat > "$CRONTAB_FILE" <<EOF
# Vaultwarden Backup Schedule
${BACKUP_CRON} /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1
EOF
  
  # 启动主服务和 supercronic（两个后台进程）
  "$exec_path" &
  SERVICE_PID=$!
  
  /usr/local/bin/supercronic "$CRONTAB_FILE" &
  CRON_PID=$!
  
  echo "✅ Backup scheduler started with supercronic"
  
  # 等待服务（任意一个失败则退出）
  wait $SERVICE_PID $CRON_PID
else
  # 仅启动 Vaultwarden（不启用备份）
  exec "$exec_path"
fi
