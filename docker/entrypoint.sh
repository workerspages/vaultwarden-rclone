#!/usr/bin/env bash
set -e

# --- 1. 优先处理 Rclone 配置 (从环境变量生成) ---
# 必须在加载 env.conf 之前处理，确保基础环境正确
if [[ -n "${RCLONE_CONF_BASE64}" ]]; then
    echo "⚙️  Generating Rclone config from environment variable..."
    mkdir -p /config/rclone
    # 使用 tr 修复可能存在的换行符、回车和空格，防止 base64 解码失败
    echo "${RCLONE_CONF_BASE64}" | tr -d '\n\r ' | base64 -d > /config/rclone/rclone.conf
    export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# --- 2. 加载持久化配置 (Web面板保存的文件) ---
# 这允许面板修改的配置(如Cron)在重启后覆盖默认环境变量
CONF_FILE="/data/env.conf"
if [[ -f "$CONF_FILE" ]]; then
    echo "📜 Loading configuration from $CONF_FILE..."
    set -a
    source "$CONF_FILE"
    set +a
fi

# --- 3. 再次检查 Rclone 配置路径 ---
# 如果 env.conf 加载后没有设置 RCLONE_CONFIG，但文件存在，强制指定
if [[ -z "${RCLONE_CONFIG}" && -f "/config/rclone/rclone.conf" ]]; then
    export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# --- 4. 初始化系统日志 (解决面板日志空白问题) ---
# 确保日志文件存在，并写入启动时间，让用户在面板看到反馈
touch /var/log/backup.log
echo "--- System Started at $(date) ---" >> /var/log/backup.log
echo "✅ Log system initialized." >> /var/log/backup.log

# --- 5. 启动 Web 控制台 (后台运行) ---
echo "🖥️  Starting Dashboard on port ${DASHBOARD_PORT:-5277}..."
# 面板自身的日志输出到 dashboard.log，避免干扰主备份日志
python3 /app/dashboard/app.py >> /var/log/dashboard.log 2>&1 &
DASH_PID=$!

# --- 6. 准备启动 Vaultwarden 主服务 ---
echo "🚀 Starting Vaultwarden service..."
exec_path="/start.sh"

# --- 7. 根据配置启动定时任务 ---
if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
  echo "📅 Configuring backup schedule: ${BACKUP_CRON}"
  
  # 创建 crontab 文件
  CRONTAB_FILE="/tmp/crontab"
  cat > "$CRONTAB_FILE" <<EOF
# Vaultwarden Backup Schedule
${BACKUP_CRON} /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1
EOF
  
  # 启动 Vaultwarden 主服务 (后台)
  "$exec_path" &
  SERVICE_PID=$!
  
  # 启动 Supercronic 调度器 (后台)
  # 关键：将调度器的日志也重定向到 backup.log，这样面板能看到 "Next time..." 等信息
  /usr/local/bin/supercronic "$CRONTAB_FILE" >> /var/log/backup.log 2>&1 &
  CRON_PID=$!
  
  echo "✅ Backup scheduler started."
  
  # 等待任意核心进程退出 (如果 VW 挂了或 Cron 挂了，容器就退出重启)
  wait -n $SERVICE_PID $CRON_PID $DASH_PID
  
else
  # 不启用备份模式
  "$exec_path" &
  SERVICE_PID=$!
  
  wait -n $SERVICE_PID $DASH_PID
fi
