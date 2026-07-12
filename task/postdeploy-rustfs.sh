#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
PREFIX="${ENV}"

RUSTFS_ROOT_USER=$(config_get rustfs_root_user 'rustfsadmin')
RUSTFS_ROOT_PASS=$(config_get rustfs_root_password 'changeme')

PF_PORT=9000
PF_PID=""

cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  rm -f /tmp/mc
}
trap cleanup EXIT

header "POSTDEPLOY RUSTFS"

# ─── WAIT FOR RUSTFS ───────────────────────────────────────────────────────────
info "waiting for rustfs pod..."
if ! k8s_wait_pod "nine" "app.kubernetes.io/name=rustfs" 60; then
  ko "rustfs: not running"
  exit 1
fi
ok "rustfs: pod running"

# ─── PORT-FORWARD ──────────────────────────────────────────────────────────────
info "starting port-forward to rustfs API..."
kubectl port-forward -n nine "svc/rustfs" "${PF_PORT}:9000" &>/dev/null &
PF_PID=$!
sleep 2

# ─── DOWNLOAD MC ───────────────────────────────────────────────────────────────
if [ ! -x /tmp/mc ]; then
  info "downloading mc client..."
  curl -sL "https://dl.min.io/client/mc/release/linux-amd64/mc" -o /tmp/mc 2>&1 | indent
  chmod +x /tmp/mc
fi

# ─── CONFIGURE MC ALIAS ───────────────────────────────────────────────────────
info "configuring mc alias with root credentials..."
/tmp/mc alias set ninekube "http://127.0.0.1:${PF_PORT}" "$RUSTFS_ROOT_USER" "$RUSTFS_ROOT_PASS" &>/dev/null

if ! /tmp/mc ls ninekube/ &>/dev/null; then
  ko "rustfs: cannot connect with root credentials"
  hint "root password is PVC-bound, use the original password or delete the PVC"
  exit 1
fi
ok "rustfs: connected with root credentials"

done_ok "rustfs configured"
