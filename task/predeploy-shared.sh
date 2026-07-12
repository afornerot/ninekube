#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"

DOMAIN=$(config_get domain 'nine.local')
MINIO_ROOT_USER=$(config_get minio_root_user 'minioroot')
MINIO_ROOT_PASS=$(config_get minio_root_password 'changeme')

header "PREDEPLOY SHARED"

ensure_namespace "nine"

# ─── SHARED CONFIGMAP ───────────────────────────────────────────────────────────
if [ -n "$DOMAIN" ]; then
  PREFIX="${ENV}"
  info "patching shared configmap..."
  apply_manifest <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PREFIX}-nine-config
  namespace: nine
data:
  DOMAIN: "${DOMAIN}"
  MINIO_HOST: "minio.${DOMAIN}"
EOF
  ok "shared configmap: patched"
fi

# ─── SHARED SECRETS ─────────────────────────────────────────────────────────────
info "patching shared secrets..."
apply_manifest <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: nine-secrets
  namespace: nine
type: Opaque
stringData:
  MINIO_ROOT_USER: "${MINIO_ROOT_USER}"
  MINIO_ROOT_PASSWORD: "${MINIO_ROOT_PASS}"
EOF
ok "shared secrets: patched"

done_ok "shared predeploy"
