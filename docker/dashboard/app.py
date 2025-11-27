import os
import subprocess
import json
from werkzeug.utils import secure_filename
from flask import Flask, render_template, request, redirect, url_for, session, flash, send_file, after_this_request

app = Flask(__name__)
app.secret_key = os.urandom(24)

# 配置
CONF_FILE = "/data/env.conf"
LOG_FILE = "/var/log/backup.log"
DASHBOARD_USER = os.environ.get("DASHBOARD_USER", "admin")
DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD", "admin")

# 需要在面板中管理的变量
# 【注意】已移除 RCLONE_CONF_BASE64，交由系统环境变量接管
MANAGED_KEYS = [
    "RCLONE_REMOTE", "BACKUP_CRON", 
    "BACKUP_FILENAME_PREFIX", "BACKUP_COMPRESSION", 
    "TELEGRAM_ENABLED", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID",
    "RETENTION_MODE", "BACKUP_RETAIN_DAYS", "BACKUP_RETAIN_COUNT"
]

def load_env_file():
    """读取配置文件"""
    env_vars = {}
    if os.path.exists(CONF_FILE):
        with open(CONF_FILE, 'r') as f:
            for line in f:
                if '=' in line and not line.strip().startswith('#'):
                    key, val = line.strip().split('=', 1)
                    val = val.strip('"').strip("'")
                    env_vars[key] = val
    return env_vars

def save_env_file(form_data):
    """保存配置"""
    lines = []
    for key in MANAGED_KEYS:
        new_val = form_data.get(key)
        # 允许写入空值，并进行转义
        val = new_val if new_val is not None else ""
        safe_val = val.replace('"', '\\"')
        lines.append(f'{key}="{safe_val}"')
    
    with open(CONF_FILE, 'w') as f:
        f.write("\n".join(lines) + "\n")

def get_remote_files():
    # 获取 Remote 地址：优先文件，其次环境
    file_vars = load_env_file()
    remote = file_vars.get("RCLONE_REMOTE")
    if not remote: 
        remote = os.environ.get("RCLONE_REMOTE", "")
        
    if not remote:
        return []
    try:
        # 获取 JSON 格式的文件列表
        cmd = ["rclone", "lsjson", remote, "--files-only", "--no-mimetype"]
        result = subprocess.check_output(cmd, timeout=15)
        files = json.loads(result)
        # 按时间倒序排列
        files.sort(key=lambda x: x.get("ModTime", ""), reverse=True)
        # 格式化大小
        for f in files:
            size = f.get("Size", 0)
            f["SizeHuman"] = f"{size / 1024 / 1024:.2f} MB"
            f["ModTime"] = f["ModTime"][:19].replace("T", " ")
        return files
    except Exception as e:
        print(f"Rclone ls error: {e}")
        return []

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

@app.route('/download/<path:filename>')
def download_file(filename):
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    
    file_vars = load_env_file()
    remote = file_vars.get("RCLONE_REMOTE")
    if not remote:
        remote = os.environ.get("RCLONE_REMOTE", "")

    if not remote:
        flash("未配置 RCLONE_REMOTE", "danger")
        return redirect(url_for('index'))

    filename = secure_filename(filename) 
    temp_dir = "/tmp/downloads"
    os.makedirs(temp_dir, exist_ok=True)
    local_path = os.path.join(temp_dir, filename)

    try:
        remote_path = f"{remote.rstrip('/')}/{filename}"
        subprocess.check_call(["rclone", "copyto", remote_path, local_path], timeout=600)
        
        @after_this_request
        def remove_file(response):
            try:
                os.remove(local_path)
            except Exception:
                pass
            return response
            
        return send_file(local_path, as_attachment=True, download_name=filename)
    except Exception as e:
        flash(f"下载失败: {str(e)}", "danger")
        return redirect(url_for('index'))

@app.route('/upload_restore', methods=['POST'])
def upload_restore():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
        
    if 'file' not in request.files:
        flash('未选择文件', 'danger')
        return redirect(url_for('index'))
        
    file = request.files['file']
    if file.filename == '':
        flash('文件名为空', 'danger')
        return redirect(url_for('index'))

    if file:
        filename = secure_filename(file.filename)
        save_path = os.path.join("/tmp", filename)
        try:
            file.save(save_path)
            process = subprocess.run(
                ["/usr/local/bin/restore.sh", save_path], 
                capture_output=True, text=True
            )
            if process.returncode == 0:
                flash(f"文件 {filename} 上传并还原成功！", "success")
            else:
                flash(f"还原失败: {process.stderr}", "danger")
        except Exception as e:
            flash(f"处理文件时出错: {str(e)}", "danger")
        finally:
            if os.path.exists(save_path):
                os.remove(save_path)
    return redirect(url_for('index'))

@app.route('/', methods=['GET', 'POST'])
def index():
    if not session.get('logged_in'):
        return redirect(url_for('login'))

    # 读取逻辑：文件优先，环境垫底
    file_vars = load_env_file()
    current_vars = {}
    
    for key in MANAGED_KEYS:
        # 1. 尝试从文件获取
        val = file_vars.get(key)
        # 2. 如果文件中没有，则使用环境变量
        if val is None:
            val = os.environ.get(key, "")
        current_vars[key] = val

    # 检查是否配置了 Config Base64 (仅用于前端显示状态)
    has_rclone_conf = "RCLONE_CONF_BASE64" in os.environ and len(os.environ["RCLONE_CONF_BASE64"]) > 10

    if request.method == 'POST':
        action = request.form.get('action')
        
        if action == 'save':
            save_env_file(request.form)
            flash('配置已保存！请重启容器以使更改生效。', 'success')
            return redirect(url_for('index'))
            
        elif action == 'backup':
            subprocess.Popen(["/usr/local/bin/backup.sh"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            flash('备份任务已在后台启动。', 'info')
            
        elif action == 'restore_latest':
            subprocess.Popen(["/usr/local/bin/restore.sh", "latest"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            flash('还原任务已启动。', 'warning')

    logs = ""
    if os.path.exists(LOG_FILE):
        try:
            logs = subprocess.check_output(['tail', '-n', '200', LOG_FILE]).decode('utf-8')
        except:
            logs = "无法读取日志"
            
    remote_files = get_remote_files()

    return render_template('index.html', login_page=False, config=current_vars, logs=logs, remote_files=remote_files, has_rclone_conf=has_rclone_conf)

if __name__ == '__main__':
    port = int(os.environ.get('DASHBOARD_PORT', 5277))
    app.run(host='0.0.0.0', port=port)
