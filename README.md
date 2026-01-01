# 🔐 Vaultwarden Extended (Rclone 备份版)

![Docker Image Size](https://img.shields.io/docker/image-size/workerspages/vaultwarden-rclone/latest)
![Docker Pulls](https://img.shields.io/docker/pulls/workerspages/vaultwarden-rclone)
![Python](https://img.shields.io/badge/Python-3.11-blue.svg)
![License](https://img.shields.io/badge/license-GPLv3-green.svg)

这是一个基于官方 `vaultwarden/server` 构建的增强版 Docker 镜像。它不仅提供了密码管理服务，还内置了 **Web 控制面板** 和 **Rclone**，实现了数据的**自动异地加密备份**、**智能保留策略**以及**一键可视化还原**。

本项目旨在解决 Vaultwarden 用户最痛点的需求：**数据安全与异地容灾**。

---

## ✨ 核心特性

*   🐳 **官方内核**：基于 `vaultwarden/server:latest` 构建，与官方版本完全同步。
*   🖥️ **可视化面板**：内置独立管理后台 (端口 `5277`)，支持 2FA 双重验证。
*   🧱 **双卷架构 (New)**：实现了数据 (`/data`) 与配置 (`/conf`) 的物理隔离。还原数据时不会丢失面板配置（如 2FA 密钥、Rclone 设置）。
*   ☁️ **多云支持**：支持 Google Drive, OneDrive, S3, MinIO, WebDAV (坚果云) 等 40+ 种存储后端。
*   🧠 **智能保留 (GFS)**：支持 Grandfather-Father-Son 策略（保留 7天/4周/12月），或简单的按数量/天数轮替。
*   🛡️ **安全增强**：
    *   控制面板支持 **TOTP 两步验证 (2FA)**。
    *   Rclone 配置通过环境变量注入，不在面板明文显示。
*   🔄 **全能还原**：
    *   支持从云端列表下载历史备份并一键还原。
    *   支持上传本地 `.tar.gz` 文件进行还原。
    *   还原后自动重启容器，立即生效。
*   🔔 **即时通知**：Telegram 机器人推送备份成功/失败消息。

---

## 🛠️ 架构说明 (重要)

本项目采用 **双卷 (Dual Volume)** 设计，以确保数据安全和配置持久化：

1.  **`/data`**：仅存放 Vaultwarden 的核心数据（数据库 `db.sqlite3`、附件、密钥等）。
2.  **`/conf`**：存放增强功能的配置文件（Web 面板设置 `env.conf`、2FA 密钥、运行日志）。

**优势**：当你执行“数据还原”时，系统只会覆盖 `/data`，而不会影响 `/conf`。这意味着**还原旧备份不会导致你的 2FA 失效或面板密码重置**。

---

## 🚀 部署指南 (Docker Compose)

### 1. 准备 Rclone 配置字符串 (Base64)
为了安全，Rclone 配置文件必须通过环境变量传入。

1.  在本地电脑（Windows/Mac/Linux）下载并安装 [Rclone](https://rclone.org/downloads/)。
2.  运行 `rclone config` 配置你的云存储（记下配置名称，例如 `my-drive`）。
3.  验证配置是否可用：`rclone lsd my-drive:`。
4.  **将配置文件转换为 Base64 字符串**：

    *   **Linux / macOS:**
        ```bash
        cat ~/.config/rclone/rclone.conf | base64 | tr -d '\n'
        ```
    *   **Windows (PowerShell):**
        ```powershell
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes("$env:USERPROFILE\.config\rclone\rclone.conf"))
        ```
    > ⚠️ **注意**：生成的字符串应该是一长串随机字符，**不要**包含命令行提示符或多余的空格。

### 2. 创建 `docker-compose.yml`

```yaml
version: '3.8'

services:
  vaultwarden:
    image: ghcr.io/workerspages/vaultwarden-rclone:latest
    container_name: vaultwarden
    restart: always
    ports:
      - "80:80"          # Vaultwarden 服务端口
      - "5277:5277"      # Web 控制面板端口 (建议不要对公网开放)
    environment:
      - TZ=Asia/Shanghai
      
      # --- Web 面板初始凭证 ---
      - DASHBOARD_USER=admin
      - DASHBOARD_PASSWORD=你的强密码
      
      # --- Rclone 配置 (必须在此设置) ---
      # 格式: <配置名称>:<路径>
      - RCLONE_REMOTE=my-drive:/vaultwarden_backup
      # 填入第 1 步生成的 Base64 字符串
      - RCLONE_CONF_BASE64=W2ppYW5ndW95dW4teXVueHpoXQp0eXBlID0gd2ViZGF2Cn...
      
      # --- 备份策略 ---
      - BACKUP_CRON=0 3 * * *         # 每天凌晨 3 点备份
      - BACKUP_COMPRESSION=gz         # 压缩格式: gz (推荐), zst, xz
      
      # --- 保留策略 ---
      - RETENTION_MODE=smart          # smart(智能), count(数量), days(天数)
      - BACKUP_RETAIN_COUNT=30        # 仅在 count 模式生效
      
      # --- 通知 (可选) ---
      - TELEGRAM_ENABLED=false
      - TELEGRAM_BOT_TOKEN=
      - TELEGRAM_CHAT_ID=

    volumes:
      - ./vw-data:/data   # Vaultwarden 数据卷
      - ./vw-conf:/conf   # 面板配置卷 (一定要挂载这个!)
```

### 3. 启动服务
```bash
docker-compose up -d
```

---

## 💻 使用指南

### 访问控制面板
访问 `http://你的IP:5277`，使用环境变量中设置的账号密码登录。

### 启用 2FA (强烈推荐)
1.  登录面板后，系统会提示“首次设置两步验证”。
2.  使用 Google Authenticator 或 Authy 扫描屏幕上的二维码。
3.  输入 6 位验证码进行绑定。
4.  绑定成功后，密钥将保存在 `/conf` 卷中，重启容器或还原数据均**不会丢失**。

### 手动还原数据
在面板的“云端备份文件”列表中：
1.  找到想要还原的备份。
2.  点击右侧红色的 **[还原]** 按钮。
3.  确认提示框。
4.  系统将自动下载备份 -> 清空当前数据 -> 解压覆盖 -> **自动重启容器**。
5.  等待约 10-30 秒，刷新 Vaultwarden 页面即可看到旧数据。

---

## ⚙️ 环境变量详细说明

| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `DASHBOARD_PORT` | `5277` | 面板端口 |
| `DASHBOARD_USER` | `admin` | 面板登录用户名 |
| `DASHBOARD_PASSWORD` | `admin` | 面板登录密码 |
| `RCLONE_REMOTE` | - | **[必填]** 远程存储路径，如 `onedrive:/backup` |
| `RCLONE_CONF_BASE64` | - | **[必填]** Rclone 配置文件的 Base64 编码 |
| `BACKUP_CRON` | `0 3 * * *` | Crontab 表达式 |
| `BACKUP_COMPRESSION` | `gz` | 压缩算法: `gz`, `zst`, `xz` |
| `RETENTION_MODE` | `smart` | `smart`: GFS 策略 (7天/4周/12月)<br>`count`: 保留最近 N 份<br>`days`: 保留最近 N 天<br>`forever`: 永久保留 |
| `BACKUP_RETAIN_COUNT` | `30` | `count` 模式下的保留数量 |
| `BACKUP_RETAIN_DAYS` | `14` | `days` 模式下的保留天数 |
| `TELEGRAM_ENABLED` | `false` | 是否开启 TG 通知 |
| `CLOUDFLARED_TOKEN` | `填入 Token` | Cloudflare Tunnel (填入Token开启) |

---

## ❓ 常见问题 (FAQ)

**Q: 还原备份后，为什么提示“用户名或密码错误”？**
A: 还原是“时光倒流”。如果你还原了 3 天前的备份，而你在 2 天前修改了 Vaultwarden 的主密码，那么还原后，你需要使用**旧的主密码**登录。

**Q: 为什么日志显示 `401 Unauthorized`？**
A: 你的 Rclone 配置有误。对于坚果云等 WebDAV，密码必须是**应用专用密码**，不能用网页登录密码。请在本地 `rclone config` 验证通过后，重新生成 Base64 并更新环境变量。

**Q: 如何升级 Rclone 版本？**
A: 修改 `Dockerfile` 中的 `ARG RCLONE_VERSION=v1.xx.x`，然后重新构建镜像。

---

## 🏗️ 开发者构建信息

如果你想自己从源码构建此镜像：

```bash
# 1. 克隆代码
git clone https://github.com/workerspages/vaultwarden-rclone.git
cd vaultwarden-rclone

# 2. 构建镜像 (推荐使用 --no-cache 避免缓存旧层)
docker build --no-cache -t vaultwarden-rclone -f docker/Dockerfile .

# 3. 运行
docker run -d --name vw -p 80:80 -p 5277:5277 \
  -e RCLONE_REMOTE=... \
  -e RCLONE_CONF_BASE64=... \
  -v $(pwd)/vw-data:/data \
  -v $(pwd)/vw-conf:/conf \
  vaultwarden-rclone
```

---

## 📝 License
MIT License. 本项目与 Bitwarden 或 Vaultwarden 官方无关联。
