import os
import subprocess
import signal
import json
import glob
from werkzeug.utils import secure_filename
from flask import Flask, render_template, request, redirect, url_for, session, flash, send_file, after_this_request

app = Flask(__name__)
app.secret_key = os.urandom(24)

# ... (原有的配置和 helper 函数保持不变) ...
CONF_FILE = "/data/env.conf"
LOG_FILE = "/var/log/backup.log"
DASHBOARD_USER = os.environ.get("DASHBOARD_USER", "admin")
DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD", "admin")
MANAGED_KEYS = [
    "RCLONE_REMOTE", "RCLONE_CONF_BASE64", "BACKUP_CRON", 
    "BACKUP_RETAIN_DAYS", "BACKUP_COMPRESSION", 
    "TELEGRAM_ENABLED", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID",
    "BACKUP_FILENAME_PREFIX"
]

def load_env_file():
    # ... (代码不变) ...
    env_vars = {}
    if os.path.exists(CONF_FILE):
        with open(CONF_FILE, 'r') as f:
            for line in f:
                if '=' in line and not line.strip().startswith('#'):
                    key, val = line.strip().split('=', 1)
                    val = val.strip('"').strip("'")
                    env_vars[key] = val
    return env_vars

def save_env_file(data):
    # ... (代码不变) ...
    lines = []
    for key in MANAGED_KEYS:
        val = data.get(key, "")
        safe_val = val.replace('"', '\\"')
        lines.append(f'{key}="{safe_val}"')
    with open(CONF_FILE, 'w') as f:
        f.write("\n".join(lines) + "\n")

# --- 新增: 获取远程文件列表 ---
def get_remote_files():
    remote = os.environ.get("RCLONE_REMOTE")
    if not remote:
        return []
    try:
        # 获取 JSON 格式的文件列表
        cmd = ["rclone", "lsjson", remote, "--files-only", "--no-mimetype"]
        result = subprocess.check_output(cmd, timeout=10)
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
    # ... (代码不变) ...
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

# --- 新增: 下载文件 ---
@app.route('/download/<path:filename>')
def download_file(filename):
    if not session.get('logged_in'):
        return redirect(url_for('login'))
        
    remote = os.environ.get("RCLONE_REMOTE")
    if not remote:
        flash("未配置 RCLONE_REMOTE", "danger")
        return redirect(url_for('index'))

    # 安全处理文件名
    filename = secure_filename(filename) 
    # 为了简化，假设文件名在根目录。如果有多级目录，需要更复杂的处理
    # 使用临时文件
    temp_dir = "/tmp/downloads"
    os.makedirs(temp_dir, exist_ok=True)
    local_path = os.path.join(temp_dir, filename)

    try:
        # 使用 rclone copyto 下载
        remote_path = f"{remote.rstrip('/')}/{filename}"
        subprocess.check_call(["rclone", "copyto", remote_path, local_path], timeout=300)
        
        # 发送文件并在发送后删除
        @after_this_request
        def remove_file(response):
            try:
                os.remove(local_path)
            except Exception as e:
                print(f"Error removing temp file: {e}")
            return response
            
        return send_file(local_path, as_attachment=True, download_name=filename)

    except subprocess.CalledProcessError:
        flash(f"从云端下载文件失败: {filename}", "danger")
        return redirect(url_for('index'))
    except Exception as e:
        flash(f"错误: {str(e)}", "danger")
        return redirect(url_for('index'))

# --- 新增: 上传并还原 ---
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
            
            # 调用 restore.sh，传入本地路径
            # 使用 wait=True 同步等待结果，因为还原通常很快（除非数据量巨大）
            # 或者也可以异步，但用户想立刻知道结果
            process = subprocess.run(
                ["/usr/local/bin/restore.sh", save_path], 
                capture_output=True, text=True
            )
            
            if process.returncode == 0:
                flash(f"文件 {filename} 上传并还原成功！(请检查日志确认详情)", "success")
            else:
                flash(f"还原失败: {process.stderr}", "danger")
                
        except Exception as e:
            flash(f"处理文件时出错: {str(e)}", "danger")
        finally:
            # 清理上传的临时文件
            if os.path.exists(save_path):
                os.remove(save_path)
                
    return redirect(url_for('index'))


@app.route('/', methods=['GET', 'POST'])
def index():
    if not session.get('logged_in'):
        return redirect(url_for('login'))

    # ... (环境变量加载逻辑不变) ...
    file_vars = load_env_file()
    current_vars = {}
    for key in MANAGED_KEYS:
        current_vars[key] = file_vars.get(key, os.environ.get(key, ""))

    if request.method == 'POST':
        action = request.form.get('action')
        
        if action == 'save':
            save_env_file(request.form)
            flash('配置已保存！请重启容器生效。', 'success')
            return redirect(url_for('index'))
            
        elif action == 'backup':
            subprocess.Popen(["/usr/local/bin/backup.sh"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            flash('备份任务已启动...', 'info')
            
        elif action == 'restore_latest':
            subprocess.Popen(["/usr/local/bin/restore.sh", "latest"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            flash('还原最新备份任务已启动...', 'warning')

    # 读取日志 (不变)
    logs = ""
    if os.path.exists(LOG_FILE):
        try:
            logs = subprocess.check_output(['tail', '-n', '200', LOG_FILE]).decode('utf-8')
        except:
            logs = "无法读取日志"
            
    # 获取云端文件列表 (新增)
    remote_files = get_remote_files()

    return render_template('index.html', login_page=False, config=current_vars, logs=logs, remote_files=remote_files)

if __name__ == '__main__':
    port = int(os.environ.get('DASHBOARD_PORT', 5277))
    app.run(host='0.0.0.0', port=port)
