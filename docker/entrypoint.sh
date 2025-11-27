#!/usr/bin/env bash
set -e

# --- 1. 优先处理 Rclone 配置 (这是修复面板显示和保留策略的关键) ---
# 确保在启动任何服务之前，配置文件已经存在
if [[ -n "${RCLONE_CONF_BASE64}" ]]; then
    echo "⚙️  Generating Rclone config from environment variable..."
    mkdir -p /config/rclone
    # 使用 tr 修复换行符问题
    echo "${RCLONE_CONF_BASE64}" | tr -d '\n\r ' | base64 -d > /config/rclone/rclone.conf
    export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# --- 2. 加载持久化配置 (Web面板保存的文件) ---
CONF_FILE="/data/env.conf"
if [[ -f "$CONF_FILE" ]]; then
    echo "📜 Loading configuration from $CONF_FILE..."
    set -a
    source "$CONF_FILE"
    set +a
fi

# --- 3. 再次检查 Rclone 配置 (防止被 env.conf 覆盖为空) ---
# 如果 env.conf 里没有定义 RCLONE_CONFIG，确保它指向我们刚才生成的文件
if [[ -z "${RCLONE_CONFIG}" && -f "/config/rclone/rclone.conf" ]]; then
    export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# --- 4. 启动 Web 控制台 (后台运行) ---
echo "🖥️  Starting Dashboard on port ${DASHBOARD_PORT:-5277}..."
# 传递当前的环境变量给 Python
python3 /app/dashboard/app.py >> /var/log/dashboard.log 2>&1 &
DASH_PID=$!

# --- 5. 启动 Vaultwarden 服务 ---
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
  
  # 等待任意进程退出
  wait -n $SERVICE_PID $CRON_PID $DASH_PID
  
else
  # 仅启动 Vaultwarden 和 面板
  "$exec_path" &
  SERVICE_PID=$!
  
  wait -n $SERVICE_PID $DASH_PID
fi
