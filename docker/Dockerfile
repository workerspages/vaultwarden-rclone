FROM vaultwarden/server:latest

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
ARG RCLONE_VERSION=v1.68.2

# 安装依赖：增加了 python3, python3-flask, python3-pip, procps
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl tzdata bash unzip jq zstd \
      python3 python3-flask python3-pip procps; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime; \
    echo $TZ > /etc/timezone; \
    dpkg-reconfigure --frontend noninteractive tzdata; \
    \
    # --- 安装 Python 库 (2FA 支持) --- \
    pip3 install pyotp qrcode --break-system-packages; \
    \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    \
    # --- Rclone 安装 --- \
    curl -fsSL -O "https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-amd64.zip"; \
    unzip "rclone-${RCLONE_VERSION}-linux-amd64.zip"; \
    mv "rclone-${RCLONE_VERSION}-linux-amd64/rclone" /usr/bin/rclone; \
    chmod +x /usr/bin/rclone; \
    rm -rf "rclone-${RCLONE_VERSION}-linux-amd64"* ; \
    \
    # --- Supercronic 安装 --- \
    SUPERCRONIC_VERSION=0.2.30; \
    curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64"; \
    chmod +x /usr/local/bin/supercronic

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/backup.sh     /usr/local/bin/backup.sh
COPY docker/restore.sh    /usr/local/bin/restore.sh
RUN chmod +x /usr/local/bin/*.sh

COPY docker/dashboard /app/dashboard
COPY docker/retention.py /app/dashboard/retention.py

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
    DASHBOARD_PORT=5277

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
