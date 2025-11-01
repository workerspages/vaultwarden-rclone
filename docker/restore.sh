#!/usr/bin/env bash
set -euo pipefail

: "${BACKUP_SRC:=/data}"
: "${RCLONE_REMOTE:=}"
: "${RESTORE_STRATEGY:=replace}"

# 用法：
#  1) restore.sh latest
#  2) restore.sh remote-path/object.tar.gz
# 要求：为确保一致性，建议在停止服务的状态下执行（或在独立一次性容器中执行）

mode="${1:-}"
if [[ -z "${mode}" ]]; then
  echo "Usage: restore.sh latest | <remote-object-path>"
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fetch_latest() {
  # 列表最新对象
  rclone lsjson "${RCLONE_REMOTE}" --files-only --fast-list \
    | jq -r 'sort_by(.ModTime)|last|.Path'
}

remote_obj="${mode}"
if [[ "${mode}" == "latest" ]]; then
  if [[ -z "${RCLONE_REMOTE}" ]]; then
    echo "RCLONE_REMOTE is not set"
    exit 1
  fi
  remote_obj="$(fetch_latest)"
fi

if [[ -z "${remote_obj}" ]]; then
  echo "No remote object to restore."
  exit 1
fi

local_archive="${work}/restore.tar"
rclone copyto "${RCLONE_REMOTE%/}/${remote_obj}" "${local_archive}"

backup_before="${BACKUP_SRC%/}.pre-restore-$(date -u +%Y%m%d-%H%M%S)"
cp -a "${BACKUP_SRC}" "${backup_before}"

# 清空并恢复
if [[ "${RESTORE_STRATEGY}" == "replace" ]]; then
  find "${BACKUP_SRC}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi

# 根据扩展名自动解压
case "${local_archive}" in
  *.tar.gz|*.tgz)    tar -xzf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.zst|*.tzst)  tar -I zstd -xf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.bz2|*.tbz2)  tar -xjf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.xz|*.txz)    tar -xJf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar)             tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
  *)                 tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
esac

echo "Restore done. Previous data saved at: ${backup_before}"
