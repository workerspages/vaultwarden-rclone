#!/usr/bin/env bash
set -e

# 定义配置路径
CONF_DIR="/conf"
CONF_FILE="${CONF_DIR}/env.conf"
LOG_FILE="${CONF_DIR}/backup.log"
TUNNEL_LOG="${CONF_DIR}/tunnel.log"

# --- 0. 自动迁移逻辑 (兼容旧版本) ---
if [[ -f "/data/env.conf" && ! -f "$CONF_FILE" ]]; then
    echo "📦 Migrating configuration from /data to /conf..."
    mv /data/env.conf "$CONF_FILE"
fi

# --- 1. 优先处理 Rclone 配置 ---
if [[ -n "${RCLONE_CONF_BASE64}" ]]; then
    echo "⚙️  Generating Rclone config from environment variable..."
    mkdir -p /config/rclone
    echo "${RCLONE_CONF_BASE64}" | tr -d '\n\r ' | base64 -d > /config/rclone/rclone.conf
    export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# --- 2. 加载持久化配置 ---
if [[ -f "$CONF_FILE" ]]; then
    echo "📜 Loading configuration from $CONF_FILE..."
    set -a
    source "$CONF_FILE"
    set +a
fi

if [[ -z "${RCLONE_CONFIG}" && -f "/config/rclone/rclone.conf" ]]; then
    export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# --- 3. 初始化日志 ---
touch "$LOG_FILE"
echo "--- System Started at $(date) ---" >> "$LOG_FILE"

# --- 4. 启动 Web 控制台 ---
echo "🖥️  Starting Dashboard..."
python3 /app/dashboard/app.py >> /var/log/dashboard.log 2>&1 &
DASH_PID=$!

# --- 5. 启动 Cloudflare Tunnel (可选) ---
if [[ -n "${CLOUDFLARED_TOKEN}" ]]; then
    echo "🚇 Starting Cloudflare Tunnel..."
    # --no-autoupdate 因为容器是不可变的，更新应通过更新镜像完成
    # protocol http2 提高稳定性
    cloudflared tunnel --no-autoupdate run --token "${CLOUDFLARED_TOKEN}" > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!
    echo "✅ Cloudflare Tunnel started (PID: $TUNNEL_PID). Logs at $TUNNEL_LOG"
else
    echo "ℹ️  Cloudflare Tunnel token not set, skipping."
    # 设为一个不存在的 PID 或空，避免 wait 报错
    TUNNEL_PID=""
fi

# --- 6. 启动 Vaultwarden ---
echo "🚀 Starting Vaultwarden service..."
exec_path="/start.sh"

if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
  echo "📅 Configuring backup schedule: ${BACKUP_CRON}"
  
  CRONTAB_FILE="/tmp/crontab"
  cat > "$CRONTAB_FILE" <<EOF
# Vaultwarden Backup Schedule
${BACKUP_CRON} /usr/local/bin/backup.sh >> ${LOG_FILE} 2>&1
EOF
  
  "$exec_path" &
  SERVICE_PID=$!
  
  /usr/local/bin/supercronic "$CRONTAB_FILE" >> "$LOG_FILE" 2>&1 &
  CRON_PID=$!
  
  echo "✅ Backup scheduler started."
  
  # 等待任意核心进程退出 (Dashboard, Vaultwarden, Cron, Tunnel)
  # 注意：如果 Tunnel 没启动，TUNNEL_PID 为空，wait 会忽略它
  wait -n $SERVICE_PID $CRON_PID $DASH_PID $TUNNEL_PID
  
else
  "$exec_path" &
  SERVICE_PID=$!
  wait -n $SERVICE_PID $DASH_PID $TUNNEL_PID
fi
