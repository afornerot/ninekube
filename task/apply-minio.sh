#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
PREFIX="${ENV}"

MINIO_ROOT_USER=$(config_get minio_root_user 'minioroot')
MINIO_ROOT_PASS=$(config_get minio_root_password 'changeme')
MINIO_ADMIN_USER=$(config_get admin_username 'admin')
MINIO_ADMIN_PASS=$(config_get admin_password 'changeme')

PF_PORT=9000
PF_PID=""

cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  rm -f /tmp/mc
}
trap cleanup EXIT

header "APPLY MINIO"

# ─── WAIT FOR MINIO ─────────────────────────────────────────────────────────────
info "waiting for minio pod..."
if ! k8s_wait_pod "nine" "app.kubernetes.io/name=minio" 60; then
  ko "minio: not running"
  exit 1
fi
ok "minio: pod running"

# ─── PORT-FORWARD ───────────────────────────────────────────────────────────────
info "starting port-forward to minio API..."
kubectl port-forward -n nine "svc/${PREFIX}-minio" "${PF_PORT}:9000" &>/dev/null &
PF_PID=$!
sleep 2

# ─── DOWNLOAD MC ────────────────────────────────────────────────────────────────
if [ ! -x /tmp/mc ]; then
  info "downloading mc client..."
  curl -sL "https://dl.min.io/client/mc/release/linux-amd64/mc" -o /tmp/mc 2>&1 | indent
  chmod +x /tmp/mc
fi

# ─── CONFIGURE MC ALIAS ────────────────────────────────────────────────────────
info "configuring mc alias with root credentials..."
/tmp/mc alias set ninekube "http://127.0.0.1:${PF_PORT}" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASS" &>/dev/null

if ! /tmp/mc admin info ninekube &>/dev/null; then
  ko "minio: cannot connect with root credentials"
  hint "root password is PVC-bound, use the original password or delete the PVC"
  exit 1
fi
ok "minio: connected with root credentials"

# ─── CREATE/UPDATE ADMIN USER ──────────────────────────────────────────────────
info "creating/updating admin user: ${MINIO_ADMIN_USER}..."
/tmp/mc admin user add ninekube "$MINIO_ADMIN_USER" "$MINIO_ADMIN_PASS" 2>&1 | indent
ok "minio user: ${MINIO_ADMIN_USER} created"

info "attaching consoleAdmin policy..."
/tmp/mc admin policy attach ninekube consoleAdmin --user "$MINIO_ADMIN_USER" 2>&1 | indent
ok "minio policy: consoleAdmin attached to ${MINIO_ADMIN_USER}"

done_ok "minio admin configured"
