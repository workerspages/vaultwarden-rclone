import os
import subprocess
import signal
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
MANAGED_KEYS = [
    "RCLONE_REMOTE", "RCLONE_CONF_BASE64", "BACKUP_CRON", 
    "BACKUP_FILENAME_PREFIX", "BACKUP_COMPRESSION", 
    "TELEGRAM_ENABLED", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID",
    "RETENTION_MODE", "BACKUP_RETAIN_DAYS", "BACKUP_RETAIN_COUNT"
]

def load_env_file():
    """只读取文件中的配置"""
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
    """保存配置：处理优先级 表单 > 文件 > 环境变量"""
    # 1. 获取当前文件中的值
    file_vars = load_env_file()
    
    lines = []
    for key in MANAGED_KEYS:
        new_val = form_data.get(key)
        
        final_val = ""
        
        # --- 特殊逻辑：RCLONE_CONF_BASE64 ---
        if key == "RCLONE_CONF_BASE64":
            if new_val and new_val.strip():
                # A. 用户填了新值 -> 使用新值
                final_val = new_val.strip()
            else:
                # B. 用户留空 -> 尝试保留旧值
                # 优先取文件里的，文件没有取环境变量里的，都没有才为空
                final_val = file_vars.get(key, os.environ.get(key, ""))
        
        # --- 普通逻辑：其他字段 ---
        else:
            # 如果表单里有这个字段（即使是空字符串），就使用表单的（允许用户清空配置）
            if new_val is not None:
                final_val = new_val
            else:
                # 表单里没传这个key（防御性），取现有状态
                final_val = file_vars.get(key, os.environ.get(key, ""))

        # 转义双引号并写入
        safe_val = final_val.replace('"', '\\"')
        lines.append(f'{key}="{safe_val}"')
    
    # 写入文件
    with open(CONF_FILE, 'w') as f:
        f.write("\n".join(lines) + "\n")

def get_remote_files():
    remote = os.environ.get("RCLONE_REMOTE")
    # 如果环境变量里没有，尝试读取一下文件（应对刚保存完还没重启的情况）
    if not remote:
         file_vars = load_env_file()
         remote = file_vars.get("RCLONE_REMOTE", "")

    if not remote:
        return []
        
    try:
        cmd = ["rclone", "lsjson", remote, "--files-only", "--no-mimetype"]
        result = subprocess.check_output(cmd, timeout=15)
        files = json.loads(result)
        files.sort(key=lambda x: x.get("ModTime", ""), reverse=True)
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
        
    remote = os.environ.get("RCLONE_REMOTE")
    if not remote:
         file_vars = load_env_file()
         remote = file_vars.get("RCLONE_REMOTE", "")

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

    # 读取配置：合并 文件配置 和 环境变量配置
    file_vars = load_env_file()
    current_vars = {}
    for key in MANAGED_KEYS:
        # 优先显示文件里存的，如果没有，显示当前环境变量里的
        current_vars[key] = file_vars.get(key, os.environ.get(key, ""))

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

    return render_template('index.html', login_page=False, config=current_vars, logs=logs, remote_files=remote_files)

if __name__ == '__main__':
    port = int(os.environ.get('DASHBOARD_PORT', 5277))
    app.run(host='0.0.0.0', port=port)
