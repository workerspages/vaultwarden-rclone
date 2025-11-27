FROM vaultwarden/server:latest

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# 安装依赖：增加了 python3, python3-flask, procps (用于进程管理)
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl tzdata bash unzip jq zstd \
      python3 python3-flask procps; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime; \
    echo $TZ > /etc/timezone; \
    dpkg-reconfigure --frontend noninteractive tzdata; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL https://rclone.org/install.sh | bash; \
    SUPERCRONIC_VERSION=0.2.30; \
    curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64"; \
    chmod +x /usr/local/bin/supercronic

# 复制脚本
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/backup.sh     /usr/local/bin/backup.sh
COPY docker/restore.sh    /usr/local/bin/restore.sh
RUN chmod +x /usr/local/bin/*.sh

# 复制 Dashboard 代码
COPY docker/dashboard /app/dashboard

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
    DASHBOARD_PORT=5277

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
