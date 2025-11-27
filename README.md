# 🔐 Vaultwarden Rclone Backup & Dashboard

![Docker Image Size](https://img.shields.io/docker/image-size/workerspages/vaultwarden-rclone/latest)
![Docker Pulls](https://img.shields.io/docker/pulls/workerspages/vaultwarden-rclone)
![Python](https://img.shields.io/badge/Python-3.9+-blue.svg)
![License](https://img.shields.io/badge/license-GPLv3-green.svg)

这是一个功能强大的 **Vaultwarden** (Bitwarden 非官方服务端) 增强版镜像。它在官方镜像的基础上，集成了 **Rclone** 自动异地备份功能，并内置了一个美观的 **Web 控制面板**，用于管理备份策略、查看日志以及一键还原数据。

## ✨ 主要特性

*   🐳 **官方内核**：基于 `vaultwarden/server:latest` 构建，保持与官方版本同步。
*   🖥️ **Web 控制面板**：内置独立管理后台 (端口 `5277`)，无需敲命令即可管理备份。
*   ☁️ **多云支持**：通过 Rclone 支持 Google Drive, OneDrive, S3, MinIO, WebDAV, 坚果云等 40+ 种存储后端。
*   🧠 **智能保留策略**：支持 GFS (Grandfather-Father-Son) 策略，自动清理旧备份（保留 7天/4周/12月），或按数量/天数保留。
*   ⏰ **稳定定时任务**：使用 `Supercronic` 替代传统 Crond，日志清晰，完美适配容器环境。
*   🔄 **全能还原**：
    *   支持从云端下载历史备份并一键还原。
    *   支持上传本地 `.tar.gz` 文件进行还原。
*   🔔 **即时通知**：支持 Telegram Bot 发送备份成功/失败通知（含详细错误日志）。

---

## 🖼️ 控制面板预览

*(建议在此处放一张面板的截图，例如 `docs/screenshot.png`)*

*   **状态概览**：查看云端文件列表、文件大小、备份时间。
*   **配置管理**：在线修改 Cron 表达式、保留策略、通知设置（重启生效）。
*   **一键操作**：手动触发立即备份、还原最新备份。

---

## 🚀 快速开始 (Docker Compose)

这是最推荐的部署方式。请创建 `docker-compose.yml`：

```yaml
version: '3.8'

services:
  vaultwarden:
    image: ghcr.io/workerspages/vaultwarden-rclone:latest
    container_name: vaultwarden
    restart: always
    ports:
      - "80:80"          # Vaultwarden 服务端口
      - "5277:5277"      # Web 控制面板端口
    environment:
      - TZ=Asia/Shanghai
      
      # --- Web 面板登录凭证 ---
      - DASHBOARD_USER=admin
      - DASHBOARD_PASSWORD=你的强密码
      
      # --- Rclone 配置 (必须通过环境变量设置) ---
      # 你的 Rclone 配置名称和路径，例如：onedrive:/backup
      - RCLONE_REMOTE=jianguoyun-yunxzh:rclone
      # 你的 rclone.conf 文件内容的 Base64 编码 (生成方法见下文)
      - RCLONE_CONF_BASE64=W2ppYW5ndW95dW4t...
      
      # --- 备份策略 ---
      - BACKUP_CRON=0 3 * * *         # 每天凌晨 3 点备份
      - BACKUP_COMPRESSION=gz         # 压缩格式: gz, zst, xz
      
      # --- 保留策略 ---
      - RETENTION_MODE=smart          # smart(智能), count(数量), days(天数), forever(永久)
      - BACKUP_RETAIN_COUNT=30        # 仅在 count 模式下生效
      - BACKUP_RETAIN_DAYS=14         # 仅在 days 模式下生效
      
      # --- Telegram 通知 (可选) ---
      - TELEGRAM_ENABLED=false
      - TELEGRAM_BOT_TOKEN=
      - TELEGRAM_CHAT_ID=

    volumes:
      - ./vw-data:/data
```

启动容器：
```bash
docker-compose up -d
```

---

## ⚙️ Rclone 配置指南 (关键步骤)

为了安全和容器的无状态化，本镜像不提供在 Web 面板直接修改 `rclone.conf` 的功能，而是通过环境变量 `RCLONE_CONF_BASE64` 注入。

### 如何获取 Base64 字符串？

1.  **在本地电脑上配置 Rclone**：
    下载 Rclone 并运行 `rclone config`，配置好你的云存储（如 OneDrive, 坚果云等）。
    *验证配置是否成功：* `rclone lsd 你的配置名:`

2.  **生成 Base64 字符串**：

    *   **Linux / macOS:**
        ```bash
        cat ~/.config/rclone/rclone.conf | base64 | tr -d '\n'
        ```

    *   **Windows (PowerShell):**
        ```powershell
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes("$env:USERPROFILE\.config\rclone\rclone.conf"))
        ```

3.  **填入环境变量**：
    将生成的一长串字符串填入 `docker-compose.yml` 的 `RCLONE_CONF_BASE64` 字段中。

    > **注意**：坚果云等 WebDAV 服务需要使用**应用专用密码**，而不是登录密码。

---

## 🧹 备份保留策略说明

通过环境变量 `RETENTION_MODE` 控制：

| 模式 | 值 | 说明 |
| :--- | :--- | :--- |
| **智能模式** (推荐) | `smart` | 基于 GFS 策略保留：<br>• 最近 7 天的每日备份<br>• 最近 4 周的每周备份<br>• 最近 12 个月的每月备份<br>• 始终保留最新一份 |
| **数量模式** | `count` | 只保留最新的 N 份备份 (由 `BACKUP_RETAIN_COUNT` 控制) |
| **天数模式** | `days` | 删除 N 天前的所有备份 (由 `BACKUP_RETAIN_DAYS` 控制) |
| **永久模式** | `forever`| 不删除任何备份 (请注意云端空间) |

---

## 🔧 环境变量详解

| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `DASHBOARD_USER` | `admin` | 面板登录用户名 |
| `DASHBOARD_PASSWORD` | `admin` | 面板登录密码 (请务必修改) |
| `RCLONE_REMOTE` | - | **[必填]** 远程存储路径，如 `onedrive:/vw_backup` |
| `RCLONE_CONF_BASE64` | - | **[必填]** Rclone 配置文件的 Base64 编码 |
| `BACKUP_CRON` | `0 3 * * *` | Crontab 表达式 (分 时 日 月 周) |
| `BACKUP_FILENAME_PREFIX`| `vaultwarden` | 备份文件名前缀 |
| `BACKUP_COMPRESSION` | `gz` | 压缩算法: `gz` (推荐), `zst` (极快), `xz` (高压缩) |
| `RETENTION_MODE` | `smart` | 见上方保留策略说明 |
| `TELEGRAM_ENABLED` | `false` | 是否开启 TG 通知 |
| `TELEGRAM_BOT_TOKEN` | - | TG 机器人 Token |
| `TELEGRAM_CHAT_ID` | - | TG 接收消息的 Chat ID |

---

## 🛠️ 高级功能与排错

### 1. 手动还原数据
如果 Web 面板无法访问，你可以进入容器内部手动还原。

*   **从云端还原最新备份**：
    ```bash
    docker exec -it vaultwarden restore.sh latest
    ```
*   **还原指定本地文件**：
    将文件放入容器内，然后运行：
    ```bash
    docker exec -it vaultwarden restore.sh /path/to/your/backup.tar.gz
    ```

### 2. 查看日志
*   **Web 面板**：登录面板，左下角黑色区域即为实时日志。
*   **命令行**：
    ```bash
    docker exec -it vaultwarden tail -f /var/log/backup.log
    ```

### 3. 数据安全
*   **备份过程**：系统会将 `/data` 目录打包。
*   **还原过程**：在覆盖数据前，系统会自动将当前的 `/data` 目录备份为 `/data.pre-restore-<日期>`，以防误操作导致数据丢失。

---

## 🏗️ 开发者构建信息

如果你想自己构建此镜像：

```bash
# 目录结构
.
├── docker/
│   ├── Dockerfile
│   ├── backup.sh      # 备份主逻辑
│   ├── restore.sh     # 还原主逻辑
│   ├── retention.py   # Python 智能清理脚本
│   └── dashboard/     # Flask Web 面板代码
│       ├── app.py
│       └── templates/

# 构建命令
docker build -t vaultwarden-rclone -f docker/Dockerfile .
```

---

## 📝 License
MIT License. 本项目与 Bitwarden 或 Vaultwarden 官方无关联。
