import os
import subprocess
import json
import pyotp
import qrcode
import io
import base64
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
    "RCLONE_REMOTE", "BACKUP_CRON", 
    "BACKUP_FILENAME_PREFIX", "BACKUP_COMPRESSION", 
    "TELEGRAM_ENABLED", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID",
    "RETENTION_MODE", "BACKUP_RETAIN_DAYS", "BACKUP_RETAIN_COUNT",
    "DASHBOARD_2FA_SECRET"  # 确保包含此项
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

def save_env_file(data_dict):
    """保存配置（支持字典更新）"""
    # 1. 读取当前文件中的最新状态
    current_vars = load_env_file()
    
    # 2. 更新传入的值
    for k, v in data_dict.items():
        if k in MANAGED_KEYS:
            current_vars[k] = v
            
    # 3. 写入文件
    lines = []
    for key in MANAGED_KEYS:
        # 优先取 current_vars (文件里的)，如果没有则取环境变量
        val = current_vars.get(key)
        if val is None:
            val = os.environ.get(key, "")
        
        safe_val = val.replace('"', '\\"')
        lines.append(f'{key}="{safe_val}"')
    
    with open(CONF_FILE, 'w') as f:
        f.write("\n".join(lines) + "\n")

# --- 核心修复：实时获取 2FA 密钥 ---
def get_2fa_secret():
    # 每次调用都重新读取文件，确保获取最新保存的密钥
    file_vars = load_env_file()
    secret = file_vars.get("DASHBOARD_2FA_SECRET")
    
    # 如果文件里没有，再试着从环境变量读（兼容通过 ENV 设置的情况）
    if not secret:
        secret = os.environ.get("DASHBOARD_2FA_SECRET", "")
        
    return secret

def get_remote_files():
    file_vars = load_env_file()
    remote = file_vars.get("RCLONE_REMOTE")
    if not remote: 
        remote = os.environ.get("RCLONE_REMOTE", "")
    if not remote: return []
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

def generate_qr_base64(provisioning_uri):
    img = qrcode.make(provisioning_uri)
    buffered = io.BytesIO()
    img.save(buffered, format="PNG")
    return base64.b64encode(buffered.getvalue()).decode("utf-8")

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        
        if username == DASHBOARD_USER and password == DASHBOARD_PASSWORD:
            # 关键：这里调用 get_2fa_secret() 会实时去读文件
            secret = get_2fa_secret()
            
            if secret and len(secret) > 10: # 简单校验长度防止空串
                # 已配置 -> 验证
                session['pre_2fa_auth'] = True
                return render_template('index.html', page='2fa_verify')
            else:
                # 未配置 -> 设置
                new_secret = pyotp.random_base32()
                session['temp_secret'] = new_secret
                session['pre_2fa_auth'] = True
                
                totp = pyotp.TOTP(new_secret)
                uri = totp.provisioning_uri(name=DASHBOARD_USER, issuer_name="Vaultwarden Backup")
                qr_b64 = generate_qr_base64(uri)
                
                return render_template('index.html', page='2fa_setup', qr_code=qr_b64, secret=new_secret)
        else:
            flash('用户名或密码错误')
            return render_template('index.html', page='login')
            
    return render_template('index.html', page='login')

@app.route('/verify_2fa', methods=['POST'])
def verify_2fa():
    if not session.get('pre_2fa_auth'):
        return redirect(url_for('login'))
    
    code = request.form.get('code')
    
    # A. 首次设置流程
    if session.get('temp_secret'):
        secret = session['temp_secret']
        totp = pyotp.TOTP(secret)
        if totp.verify(code):
            # 验证通过 -> 保存到文件
            save_env_file({"DASHBOARD_2FA_SECRET": secret})
            
            session.pop('temp_secret', None)
            session.pop('pre_2fa_auth', None)
            session['logged_in'] = True
            flash('2FA 设置成功并已登录！密钥已保存。', 'success')
            return redirect(url_for('index'))
            
    # B. 登录验证流程
    else:
        secret = get_2fa_secret()
        if secret:
            totp = pyotp.TOTP(secret)
            if totp.verify(code):
                session.pop('pre_2fa_auth', None)
                session['logged_in'] = True
                return redirect(url_for('index'))
    
    flash('验证码错误', 'danger')
    # 返回原页面
    if session.get('temp_secret'):
        totp = pyotp.TOTP(session['temp_secret'])
        uri = totp.provisioning_uri(name=DASHBOARD_USER, issuer_name="Vaultwarden Backup")
        qr_b64 = generate_qr_base64(uri)
        return render_template('index.html', page='2fa_setup', qr_code=qr_b64, secret=session['temp_secret'])
    else:
        return render_template('index.html', page='2fa_verify')

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/restore_file', methods=['POST'])
def restore_file():
    if not session.get('logged_in'): return redirect(url_for('login'))
    filename = secure_filename(request.form.get('filename'))
    subprocess.Popen(["/usr/local/bin/restore.sh", filename], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    flash(f'正在还原：{filename}', 'warning')
    return redirect(url_for('index'))

@app.route('/download/<path:filename>')
def download_file(filename):
    if not session.get('logged_in'): return redirect(url_for('login'))
    file_vars = load_env_file()
    remote = file_vars.get("RCLONE_REMOTE", os.environ.get("RCLONE_REMOTE", ""))
    if not remote: return redirect(url_for('index'))
    filename = secure_filename(filename)
    local_path = os.path.join("/tmp/downloads", filename)
    os.makedirs("/tmp/downloads", exist_ok=True)
    try:
        subprocess.check_call(["rclone", "copyto", f"{remote.rstrip('/')}/{filename}", local_path], timeout=600)
        @after_this_request
        def remove_file(res):
            try: os.remove(local_path)
            except: pass
            return res
        return send_file(local_path, as_attachment=True, download_name=filename)
    except:
        return redirect(url_for('index'))

@app.route('/upload_restore', methods=['POST'])
def upload_restore():
    if not session.get('logged_in'): return redirect(url_for('login'))
    file = request.files.get('file')
    if file and file.filename:
        filename = secure_filename(file.filename)
        save_path = os.path.join("/tmp", filename)
        file.save(save_path)
        subprocess.run(["/usr/local/bin/restore.sh", save_path])
        if os.path.exists(save_path): os.remove(save_path)
        flash("上传并还原任务已启动", "success")
    return redirect(url_for('index'))

@app.route('/', methods=['GET', 'POST'])
def index():
    if not session.get('logged_in'):
        return redirect(url_for('login'))

    file_vars = load_env_file()
    current_vars = {}
    for key in MANAGED_KEYS:
        val = file_vars.get(key)
        if val is None: val = os.environ.get(key, "")
        current_vars[key] = val

    has_rclone_conf = "RCLONE_CONF_BASE64" in os.environ and len(os.environ["RCLONE_CONF_BASE64"]) > 10
    
    # 检查是否开启了 2FA (用于显示 Badge)
    has_2fa = False
    secret = get_2fa_secret()
    if secret and len(secret) > 10:
        has_2fa = True

    if request.method == 'POST':
        action = request.form.get('action')
        
        if action == 'save':
            # 如果是表单提交，需要注意不要丢失 2FA 密钥
            # 因为 save_env_file 会重写整个文件
            # 这里我们把当前的 2FA 密钥塞回表单数据里（如果它不在表单里的话）
            form_data = request.form.to_dict()
            if 'DASHBOARD_2FA_SECRET' not in form_data:
                form_data['DASHBOARD_2FA_SECRET'] = get_2fa_secret()
            
            save_env_file(form_data)
            flash('配置已保存！需重启生效。', 'success')
            return redirect(url_for('index'))
            
        elif action == 'backup':
            subprocess.Popen(["/usr/local/bin/backup.sh"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            flash('备份任务已启动。', 'info')
            
        elif action == 'restore_latest':
            subprocess.Popen(["/usr/local/bin/restore.sh", "latest"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            flash('还原任务已启动。', 'warning')
            
        elif action == 'reset_2fa':
            save_env_file({"DASHBOARD_2FA_SECRET": ""})
            session.clear()
            flash('2FA 已重置，请重新登录并绑定。', 'warning')
            return redirect(url_for('login'))

    logs = ""
    if os.path.exists(LOG_FILE):
        try: logs = subprocess.check_output(['tail', '-n', '200', LOG_FILE]).decode('utf-8')
        except: logs = "Logs unavailable"
            
    remote_files = get_remote_files()

    return render_template('index.html', page='dashboard', config=current_vars, logs=logs, remote_files=remote_files, has_rclone_conf=has_rclone_conf, has_2fa=has_2fa)

if __name__ == '__main__':
    port = int(os.environ.get('DASHBOARD_PORT', 5277))
    app.run(host='0.0.0.0', port=port)
