import os
import subprocess
import signal
from flask import Flask, render_template, request, redirect, url_for, session, flash

app = Flask(__name__)
app.secret_key = os.urandom(24)

# 配置
CONF_FILE = "/data/env.conf"
LOG_FILE = "/var/log/backup.log"
DASHBOARD_USER = os.environ.get("DASHBOARD_USER", "admin")
DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD", "admin")

# 需要在面板中管理的变量
MANAGED_KEYS = [
    "RCLONE_REMOTE", "RCLONE_CONF_BASE64", "BACKUP_CRON", 
    "BACKUP_RETAIN_DAYS", "BACKUP_COMPRESSION", 
    "TELEGRAM_ENABLED", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID",
    "BACKUP_FILENAME_PREFIX"
]

def load_env_file():
    env_vars = {}
    if os.path.exists(CONF_FILE):
        with open(CONF_FILE, 'r') as f:
            for line in f:
                if '=' in line and not line.strip().startswith('#'):
                    key, val = line.strip().split('=', 1)
                    # 去除可能的引号
                    val = val.strip('"').strip("'")
                    env_vars[key] = val
    return env_vars

def save_env_file(data):
    lines = []
    for key in MANAGED_KEYS:
        val = data.get(key, "")
        # 转义双引号
        safe_val = val.replace('"', '\\"')
        lines.append(f'{key}="{safe_val}"')
    
    with open(CONF_FILE, 'w') as f:
        f.write("\n".join(lines) + "\n")

def restart_supercronic():
    # 查找并杀掉 supercronic 进程，entrypoint.sh 会自动监测并重启它，或者我们这里不杀，
    # 而是重新生成 crontab 并让 supercronic 重新加载 (supercronic 不支持 reload，通常重启容器最稳)
    # 这里我们采用 "Write config -> User must restart container" 或者简单的杀掉进程触发重启
    # 简单策略：仅保存配置。为了生效，建议用户重启容器。
    # 但为了 Cron 生效，我们可以尝试重新生成 crontab
    cron_exp = request.form.get("BACKUP_CRON", "0 3 * * *")
    with open("/tmp/crontab", "w") as f:
        f.write(f"{cron_exp} /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1\n")
    
    # 杀掉 supercronic，entrypoint.sh 里没有做自动重启 loop，所以这里最好提示用户重启
    pass

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form['username'] == DASHBOARD_USER and request.form['password'] == DASHBOARD_PASSWORD:
            session['logged_in'] = True
            return redirect(url_for('index'))
        else:
            flash('用户名或密码错误')
    return render_template('index.html', login_page=True)

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/', methods=['GET', 'POST'])
def index():
    if not session.get('logged_in'):
        return redirect(url_for('login'))

    # 读取当前生效的环境变量 (优先读取文件，否则读取系统环境)
    file_vars = load_env_file()
    current_vars = {}
    for key in MANAGED_KEYS:
        current_vars[key] = file_vars.get(key, os.environ.get(key, ""))

    if request.method == 'POST':
        action = request.form.get('action')
        
        if action == 'save':
            save_env_file(request.form)
            flash('配置已保存！请重启容器以使所有更改（特别是 Cron）完全生效。', 'success')
            return redirect(url_for('index'))
            
        elif action == 'backup':
            # 异步执行备份
            subprocess.Popen(["/usr/local/bin/backup.sh"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            flash('备份任务已在后台启动，请查看日志。', 'info')
            
        elif action == 'restore_latest':
            # 简单调用 restore.sh latest
            subprocess.Popen(["/usr/local/bin/restore.sh", "latest"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            flash('还原任务(Latest)已启动，这可能需要几分钟，请关注日志。', 'warning')

    # 读取日志
    logs = ""
    if os.path.exists(LOG_FILE):
        # 读取最后 200 行
        try:
            logs = subprocess.check_output(['tail', '-n', '200', LOG_FILE]).decode('utf-8')
        except:
            logs = "无法读取日志"

    return render_template('index.html', login_page=False, config=current_vars, logs=logs)

if __name__ == '__main__':
    port = int(os.environ.get('DASHBOARD_PORT', 5277))
    app.run(host='0.0.0.0', port=port)
