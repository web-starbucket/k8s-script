#!/usr/bin/env bash
set -uo pipefail

# Install oss.conf as /etc/rclone/oss.conf with mode 0600.
CONFIG="${RCLONE_CONFIG_FILE:-/etc/rclone/oss.conf}"
SRC="${OSS_SOURCE:-oss:obsbot-static-resource-cn/website/obsbot-website/beta}"
DEST="${NFS_DEST:-/data/nfs/shared/website/gray}"
INTERVAL="${SYNC_INTERVAL_SECONDS:-60}"

if [[ ! -r "${CONFIG}" ]]; then
  echo "ERROR: rclone config is not readable: ${CONFIG}" >&2
  exit 1
fi
mkdir -p "${DEST}"

while true; do
  echo "[$(date --iso-8601=seconds)] sync start: ${SRC} -> ${DEST}"
  if rclone copy \
      --config="${CONFIG}" \
      --fast-list \
      --transfers=8 \
      --checkers=16 \
      --stats=30s \
      --stats-one-line \
      --log-level=INFO \
      "${SRC}" "${DEST}"; then
    echo "[$(date --iso-8601=seconds)] sync complete"
  else
    echo "[$(date --iso-8601=seconds)] sync failed; retrying after ${INTERVAL}s" >&2
  fi
  sleep "${INTERVAL}"
done
