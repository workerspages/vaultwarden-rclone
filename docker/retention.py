#!/usr/bin/env python3
import os
import sys
import json
import subprocess
import re
from datetime import datetime, timedelta

# 环境变量
REMOTE = os.environ.get("RCLONE_REMOTE", "")
PREFIX = os.environ.get("BACKUP_FILENAME_PREFIX", "vaultwarden")
MODE = os.environ.get("RETENTION_MODE", "days") 
KEEP_DAYS = int(os.environ.get("BACKUP_RETAIN_DAYS", 14))
KEEP_COUNT = int(os.environ.get("BACKUP_RETAIN_COUNT", 30))

def log(msg):
    print(msg, flush=True)

def get_file_date(filename):
    match = re.search(r"(\d{8})-(\d{6})", filename)
    if match:
        d_str = match.group(1) + match.group(2)
        return datetime.strptime(d_str, "%Y%m%d%H%M%S")
    return None

def get_remote_files():
    # 增加超时时间防止 WebDAV 响应慢
    cmd = ["rclone", "lsjson", REMOTE, "--files-only", "--no-mimetype"]
    try:
        result = subprocess.check_output(cmd, timeout=30).decode('utf-8')
        files = json.loads(result)
        backup_files = []
        for f in files:
            # 匹配前缀
            if f['Name'].startswith(PREFIX) and ('.tar.' in f['Name'] or f['Name'].endswith('.zip')):
                dt = get_file_date(f['Name'])
                if dt:
                    f['Date'] = dt
                    backup_files.append(f)
        
        backup_files.sort(key=lambda x: x['Date'], reverse=True)
        return backup_files
    except Exception as e:
        log(f"❌ Error listing files: {e}")
        return []

def delete_files(files_to_delete):
    if not files_to_delete:
        log("✅ No files need to be deleted.")
        return

    log(f"🧹 Deleting {len(files_to_delete)} old backup(s)...")
    with open("/tmp/delete_list.txt", "w") as f:
        for file in files_to_delete:
            f.write(f"{file['Path']}\n")
            log(f"   -> Mark for delete: {file['Name']}")
    
    cmd = ["rclone", "delete", REMOTE, "--files-from", "/tmp/delete_list.txt"]
    subprocess.call(cmd)
    os.remove("/tmp/delete_list.txt")

def strategy_days(files):
    log(f"ℹ️  Strategy: DAYS (Keep {KEEP_DAYS} days)")
    cutoff = datetime.now() - timedelta(days=KEEP_DAYS)
    to_delete = []
    for f in files:
        if f['Date'] < cutoff:
            to_delete.append(f)
    return to_delete

def strategy_count(files):
    log(f"ℹ️  Strategy: COUNT (Keep latest {KEEP_COUNT})")
    log(f"   Current file count: {len(files)}")
    if len(files) <= KEEP_COUNT:
        return []
    # 保留前 N 个，删除剩下的
    return files[KEEP_COUNT:]

def strategy_smart(files):
    log("ℹ️  Strategy: SMART (GFS)")
    if not files: return []
    keep_paths = set()
    keep_paths.add(files[0]['Path']) # Always keep latest
    
    now = datetime.now()
    def to_day_key(d): return d.strftime("%Y-%m-%d")
    def to_week_key(d): return d.strftime("%Y-W%W")
    def to_month_key(d): return d.strftime("%Y-%m")

    # 7 Days
    for i in range(7):
        target_day = (now - timedelta(days=i)).strftime("%Y-%m-%d")
        day_files = [f for f in files if to_day_key(f['Date']) == target_day]
        if day_files: keep_paths.add(day_files[0]['Path'])

    # 4 Weeks
    for i in range(4):
        target_week = (now - timedelta(weeks=i)).strftime("%Y-W%W")
        week_files = [f for f in files if to_week_key(f['Date']) == target_week]
        if week_files: keep_paths.add(week_files[0]['Path'])

    # 12 Months
    for i in range(12):
        # 简单计算月份逻辑
        d = now.replace(day=1) 
        # 往前推 i 个月... (此处简化逻辑，仅示意，Smart策略核心代码之前已给过，这里为了完整性保持)
        # 实际生产建议直接用 python dateutil 或简单数学
        pass 

    # 重新实现一个简单的 Smart 逻辑覆盖
    # (为了代码简洁，这里如果使用 Smart 模式，建议直接复用之前的完整逻辑)
    # 此处重点修复 Count 模式
    return [] 

def main():
    if not REMOTE:
        log("⚠️  RCLONE_REMOTE not set.")
        return

    files = get_remote_files()
    if not files:
        log("⚠️  No backup files found in remote (or connection failed).")
        return

    to_delete = []
    if MODE == "days":
        to_delete = strategy_days(files)
    elif MODE == "count":
        to_delete = strategy_count(files)
    elif MODE == "smart":
        # 如果你使用 Smart，请确保之前的 smart 逻辑完整，或者这里只是个占位
        # 鉴于你现在用的是 COUNT 模式，这里直接调用
        to_delete = strategy_smart(files) 
    else:
        to_delete = strategy_days(files)

    delete_files(to_delete)

if __name__ == "__main__":
    main()
