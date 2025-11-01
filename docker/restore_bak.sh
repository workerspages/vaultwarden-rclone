#!/usr/bin/env bash
set -euo pipefail

: "${BACKUP_SRC:=/data}"
: "${RESTORE_STRATEGY:=replace}"

# 自动加载 rclone 配置
if [[ -z "${RCLONE_CONFIG:-}" && -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

mode="${1:-}"
if [[ -z "${mode}" ]]; then
  echo "Usage: restore.sh latest | <remote-object-filename>"
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fetch_latest() {
  if ! rclone lsjson "${RCLONE_REMOTE}" --files-only --fast-list >"${work}/ls.json"; then
    echo "Error: Failed to list remote files"
    exit 1
  fi
  jq -r 'sort_by(.ModTime)|last|.Path' <"${work}/ls.json"
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
  echo "Error: No remote object to restore"
  exit 1
fi

local_archive="${work}/restore.tar"
if ! rclone copyto "${RCLONE_REMOTE%/}/${remote_obj}" "${local_archive}"; then
  echo "Error: Failed to download backup file"
  exit 1
fi

backup_before="${BACKUP_SRC%/}.pre-restore-$(date -u +%Y%m%d-%H%M%S)"
cp -a "${BACKUP_SRC}" "${backup_before}"

if [[ "${RESTORE_STRATEGY}" == "replace" ]]; then
  find "${BACKUP_SRC}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi

case "${local_archive}" in
  *.tar.gz|*.tgz)    tar -xzf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.zst|*.tzst)  tar -I zstd -xf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.bz2|*.tbz2)  tar -xjf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.xz|*.txz)    tar -xJf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar)             tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
  *)                 tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
esac

echo "✅ Restore done. Previous data saved at: ${backup_before}"
