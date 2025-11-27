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

CONF_FILE = "/conf/env.conf"
LOG_FILE = "/conf/backup.log"

DASHBOARD_USER = os.environ.get("DASHBOARD_USER", "admin")
DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD", "admin")

# 增加 CLOUDFLARED_TOKEN
MANAGED_KEYS = [
    "RCLONE_REMOTE", "BACKUP_CRON", 
    "BACKUP_FILENAME_PREFIX", "BACKUP_COMPRESSION", 
    "TELEGRAM_ENABLED", "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID",
    "RETENTION_MODE", "BACKUP_RETAIN_DAYS", "BACKUP_RETAIN_COUNT",
    "DASHBOARD_2FA_SECRET",
    "CLOUDFLARED_TOKEN" 
]

def load_env_file():
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
    current_vars = load_env_file()
    for k, v in data_dict.items():
        if k in MANAGED_KEYS:
            current_vars[k] = v
    
    lines = []
    for key in MANAGED_KEYS:
        val = current_vars.get(key)
        if val is None: val = os.environ.get(key, "")
        safe_val = val.replace('"', '\\"')
        lines.append(f'{key}="{safe_val}"')
    
    with open(CONF_FILE, 'w') as f:
        f.write("\n".join(lines) + "\n")

def get_2fa_secret():
    file_vars = load_env_file()
    secret = file_vars.get("DASHBOARD_2FA_SECRET")
    if not secret: secret = os.environ.get("DASHBOARD_2FA_SECRET", "")
    return secret

# ... (get_remote_files, generate_qr_base64 等 Helper 函数保持不变) ...
def get_remote_files():
    file_vars = load_env_file()
    remote = file_vars.get("RCLONE_REMOTE")
    if not remote: remote = os.environ.get("RCLONE_REMOTE", "")
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
    except:
        return []

def generate_qr_base64(uri):
    img = qrcode.make(uri)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("utf-8")

# ... (Login, 2FA verify 保持不变) ...
@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        u = request.form.get('username')
        p = request.form.get('password')
        if u == DASHBOARD_USER and p == DASHBOARD_PASSWORD:
            s = get_2fa_secret()
            if s and len(s)>10:
                session['pre_2fa_auth'] = True
                return render_template('index.html', page='2fa_verify')
            else:
                new_s = pyotp.random_base32()
                session['temp_secret'] = new_s
                session['pre_2fa_auth'] = True
                totp = pyotp.TOTP(new_s)
                uri = totp.provisioning_uri(name=DASHBOARD_USER, issuer_name="Vaultwarden Backup")
                return render_template('index.html', page='2fa_setup', qr_code=generate_qr_base64(uri), secret=new_s)
        else:
            flash('用户名或密码错误')
    return render_template('index.html', page='login')

@app.route('/verify_2fa', methods=['POST'])
def verify_2fa():
    if not session.get('pre_2fa_auth'): return redirect(url_for('login'))
    code = request.form.get('code')
    if session.get('temp_secret'):
        s = session['temp_secret']
        if pyotp.TOTP(s).verify(code):
            save_env_file({"DASHBOARD_2FA_SECRET": s})
            session.pop('temp_secret', None); session.pop('pre_2fa_auth', None); session['logged_in'] = True
            flash('2FA 设置成功！', 'success')
            return redirect(url_for('index'))
    else:
        s = get_2fa_secret()
        if s and pyotp.TOTP(s).verify(code):
            session.pop('pre_2fa_auth', None); session['logged_in'] = True
            return redirect(url_for('index'))
    flash('验证码错误', 'danger')
    if session.get('temp_secret'):
        uri = pyotp.TOTP(session['temp_secret']).provisioning_uri(name=DASHBOARD_USER, issuer_name="Vaultwarden Backup")
        return render_template('index.html', page='2fa_setup', qr_code=generate_qr_base64(uri), secret=session['temp_secret'])
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
        flash("任务已启动", "success")
    return redirect(url_for('index'))

@app.route('/', methods=['GET', 'POST'])
def index():
    if not session.get('logged_in'): return redirect(url_for('login'))
    file_vars = load_env_file()
    current_vars = {}
    for key in MANAGED_KEYS:
        val = file_vars.get(key)
        if val is None: val = os.environ.get(key, "")
        current_vars[key] = val
    
    has_rclone_conf = "RCLONE_CONF_BASE64" in os.environ and len(os.environ["RCLONE_CONF_BASE64"]) > 10
    
    # 2FA 状态
    s = get_2fa_secret()
    has_2fa = s and len(s) > 10
    
    # Tunnel 状态检测：如果 Token 存在则认为已启用
    token = current_vars.get("CLOUDFLARED_TOKEN")
    has_tunnel = token and len(token) > 10

    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'save':
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
            flash('2FA 已重置。', 'warning')
            return redirect(url_for('login'))

    logs = ""
    if os.path.exists(LOG_FILE):
        try: logs = subprocess.check_output(['tail', '-n', '200', LOG_FILE]).decode('utf-8')
        except: logs = "Logs unavailable"
    
    remote_files = get_remote_files()
    return render_template('index.html', page='dashboard', config=current_vars, logs=logs, remote_files=remote_files, has_rclone_conf=has_rclone_conf, has_2fa=has_2fa, has_tunnel=has_tunnel)

if __name__ == '__main__':
    port = int(os.environ.get('DASHBOARD_PORT', 5277))
    app.run(host='0.0.0.0', port=port)
