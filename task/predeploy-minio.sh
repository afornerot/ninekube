#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
PREFIX="${ENV}"

MINIO_ROOT_USER=$(config_get minio_root_user 'minioroot')
MINIO_ROOT_PASS=$(config_get minio_root_password 'changeme')

header "PREDEPLOY MINIO"

# ─── MINIO SECRET ───────────────────────────────────────────────────────────────
info "creating minio secret..."
apply_manifest <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: minio-secret
  namespace: nine
type: Opaque
stringData:
  root-user: "${MINIO_ROOT_USER}"
  root-password: "${MINIO_ROOT_PASS}"
EOF
ok "minio secret: created"

done_ok "minio predeploy"
