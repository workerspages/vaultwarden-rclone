FROM vaultwarden/server:latest

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=${TZ:-UTC}

# 基础工具 + rclone + supercronic + curl（用于 Telegram 通知）
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl tzdata bash unzip; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL https://rclone.org/install.sh | bash; \
    SUPERCRONIC_VERSION=0.2.30; \
    curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64"; \
    chmod +x /usr/local/bin/supercronic

# 脚本
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/backup.sh     /usr/local/bin/backup.sh
COPY docker/restore.sh    /usr/local/bin/restore.sh
RUN chmod +x /usr/local/bin/*.sh

# 默认环境变量（可在 PaaS 上覆盖）
ENV BACKUP_ENABLED=true \
    BACKUP_CRON="0 3 * * *" \
    BACKUP_SRC="/data" \
    BACKUP_FILENAME_PREFIX="vaultwarden" \
    BACKUP_COMPRESSION="gz" \
    BACKUP_RETAIN_DAYS=14 \
    RCLONE_CONF_BASE64="" \
    RCLONE_REMOTE="" \
    RCLONE_FLAGS="--checksum --transfers=4 --checkers=8 --fast-list" \
    RESTORE_STRATEGY="replace" \
    TZ="Asia/Shanghai" \
    TELEGRAM_ENABLED=false \
    TELEGRAM_BOT_TOKEN="" \
    TELEGRAM_CHAT_ID="" \
    TELEGRAM_MESSAGE="Vaultwarden backup failed: %ERROR% at %TIME%"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
