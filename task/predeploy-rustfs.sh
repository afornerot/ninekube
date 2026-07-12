#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
PREFIX="${ENV}"

RUSTFS_ROOT_USER=$(config_get rustfs_root_user 'rustfsadmin')
RUSTFS_ROOT_PASS=$(config_get rustfs_root_password 'changeme')

header "PREDEPLOY RUSTFS"

# ─── RUSTFS SECRET ─────────────────────────────────────────────────────────────
info "creating rustfs secret..."
apply_manifest <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: rustfs-secret
  namespace: nine
type: Opaque
stringData:
  root-user: "${RUSTFS_ROOT_USER}"
  root-password: "${RUSTFS_ROOT_PASS}"
EOF
ok "rustfs secret: created"

done_ok "rustfs predeploy"
