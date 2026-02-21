FROM vaultwarden/server:latest

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# Rclone 需要升级修改最新版本号后重新部署
ARG RCLONE_VERSION=v1.68.2

# 安装依赖
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
  ca-certificates curl tzdata bash unzip jq zstd \
  python3 python3-pip python3-setuptools procps; \
  \
  ln -snf /usr/share/zoneinfo/$TZ /etc/localtime; \
  echo $TZ > /etc/timezone; \
  dpkg-reconfigure --frontend noninteractive tzdata; \
  \
  pip3 install --upgrade pip --break-system-packages; \
  pip3 install flask pyotp qrcode pillow --break-system-packages; \
  \
  apt-get clean; \
  rm -rf /var/lib/apt/lists/*; \
  \
  # --- Rclone 安装 ---
  curl -fsSL -O "https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-amd64.zip"; \
  unzip "rclone-${RCLONE_VERSION}-linux-amd64.zip"; \
  mv "rclone-${RCLONE_VERSION}-linux-amd64/rclone" /usr/bin/rclone; \
  chmod +x /usr/bin/rclone; \
  rm -rf "rclone-${RCLONE_VERSION}-linux-amd64"* ; \
  \
  # --- Supercronic 安装 ---
  SUPERCRONIC_VERSION=0.2.30; \
  curl -fsSL -o /usr/local/bin/supercronic \
  "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64"; \
  chmod +x /usr/local/bin/supercronic; \
  \
  # --- Cloudflared 安装 (新增) ---
  curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64; \
  chmod +x /usr/local/bin/cloudflared; \
  \
  # --- Caddy 安装 ---
  CADDY_VERSION=2.9.1; \
  CADDY_ARCH=$(dpkg --print-architecture); \
  curl -fsSL -o /tmp/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${CADDY_ARCH}.tar.gz"; \
  tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy; \
  chmod +x /usr/local/bin/caddy; \
  rm -f /tmp/caddy.tar.gz; \
  \
  # 创建独立的配置目录
  mkdir -p /conf; \
  chmod 777 /conf

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/backup.sh     /usr/local/bin/backup.sh
COPY docker/restore.sh    /usr/local/bin/restore.sh
RUN chmod +x /usr/local/bin/*.sh

COPY docker/dashboard /app/dashboard
COPY docker/retention.py /app/dashboard/retention.py
COPY docker/Caddyfile /etc/caddy/Caddyfile

# 环境变量默认值
ENV BACKUP_ENABLED=true \
  BACKUP_CRON="0 3 * * *" \
  BACKUP_SRC="/data" \
  BACKUP_FILENAME_PREFIX="vaultwarden" \
  BACKUP_COMPRESSION="gz" \
  BACKUP_RETAIN_DAYS=14 \
  CLEANUP_METHOD="min-age" \
  RCLONE_CONF_BASE64="" \
  RCLONE_REMOTE="" \
  RCLONE_FLAGS="--checksum --transfers=4 --checkers=8 --fast-list" \
  RESTORE_STRATEGY="replace" \
  ROCKET_PORT=8080 \
  CLOUDFLARED_TOKEN=""

# 声明两个卷
VOLUME ["/data", "/conf"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
