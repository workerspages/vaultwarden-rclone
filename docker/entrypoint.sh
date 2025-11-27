#!/usr/bin/env bash
set -e

# --- 1. 加载持久化配置 (Web面板保存的文件) ---
CONF_FILE="/data/env.conf"
if [[ -f "$CONF_FILE" ]]; then
    echo "📜 Loading configuration from $CONF_FILE..."
    # 使用 export 导出变量，使其对当前 shell 及子进程生效
    set -a
    source "$CONF_FILE"
    set +a
fi

# --- 2. 启动 Web 控制台 (后台运行) ---
echo "🖥️  Starting Dashboard on port ${DASHBOARD_PORT:-5277}..."
python3 /app/dashboard/app.py >> /var/log/dashboard.log 2>&1 &
DASH_PID=$!

# --- 3. 启动 Vaultwarden 服务 ---
echo "🚀 Starting Vaultwarden service..."
exec_path="/start.sh"
# 确保日志文件存在
touch /var/log/backup.log

# 如果启用备份，创建并启动定时任务
if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
  echo "📅 Configuring backup schedule: ${BACKUP_CRON}"
  
  # 创建临时 crontab 文件
  CRONTAB_FILE="/tmp/crontab"
  cat > "$CRONTAB_FILE" <<EOF
# Vaultwarden Backup Schedule
${BACKUP_CRON} /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1
EOF
  
  # 启动主服务和 supercronic
  "$exec_path" &
  SERVICE_PID=$!
  
  /usr/local/bin/supercronic "$CRONTAB_FILE" &
  CRON_PID=$!
  
  echo "✅ Backup scheduler started."
  
  # 等待任意进程退出 (如果 VW 挂了或 Cron 挂了，容器就退出)
  wait -n $SERVICE_PID $CRON_PID $DASH_PID
  
else
  # 仅启动 Vaultwarden 和 面板
  "$exec_path" &
  SERVICE_PID=$!
  
  wait -n $SERVICE_PID $DASH_PID
fi
