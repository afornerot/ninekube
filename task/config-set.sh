#!/bin/bash
source "$(dirname "$0")/helpers.sh"

header "CONFIG SET"

# ─── KUBECONFIG ─────────────────────────────────────────────────────────────────
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
  mkdir -p ~/.kube
  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
  sudo chown "$(id -u):$(id -g)" ~/.kube/config
  chmod 600 ~/.kube/config
  ok "kubeconfig: copied to ~/.kube/config"
fi

dim "Press Enter to keep the value shown in brackets"

# ─── DOMAIN ──────────────────────────────────────────────────────────────────────
section "Domain"
DOMAIN=$(ask_value "Base domain" "$(config_get domain 'nine.local')")
config_set domain "$DOMAIN"

CERT_TYPE=$(ask_value "Certificate type (self-signed / letsencrypt-staging / letsencrypt-prod)" "$(config_get cert_type 'self-signed')")
config_set cert_type "$CERT_TYPE"

if [ "$CERT_TYPE" != "self-signed" ]; then
  EMAIL=$(ask_value "Let's Encrypt email" "$(config_get email "admin@${DOMAIN}")")
  config_set email "$EMAIL"
else
  EMAIL="admin@${DOMAIN}"
fi

# ─── CLUSTER ADMIN ──────────────────────────────────────────────────────────────
section "Cluster Admin"
ADMIN_USER=$(ask_value "Admin username" "$(config_get admin_username 'admin')")
config_set admin_username "$ADMIN_USER"

ADMIN_EMAIL=$(ask_value "Admin email" "$(config_get admin_email "admin@${DOMAIN}")")
config_set admin_email "$ADMIN_EMAIL"

ADMIN_PASS=$(ask_value_constrained "Admin password" "$(config_get admin_password 'changeme')" 8 40)
config_set admin_password "$ADMIN_PASS"

# ─── POSTGRES ────────────────────────────────────────────────────────────────────
section "PostgreSQL"
PG_PASS=$(ask_value "PostgreSQL password" "$(config_get pg_password 'changeme')")
config_set pg_password "$PG_PASS"

# ─── MINIO ───────────────────────────────────────────────────────────────────────
section "MinIO (Object Storage)"
MINIO_ROOT_USER=$(ask_value "MinIO root username (first setup only, stored permanently)" "$(config_get minio_root_user 'minioroot')")
config_set minio_root_user "$MINIO_ROOT_USER"

MINIO_ROOT_PASS=$(ask_value_constrained "MinIO root password (first setup only, stored permanently)" "$(config_get minio_root_password 'changeme')" 8 40)
config_set minio_root_password "$MINIO_ROOT_PASS"

# ─── GENERATE KUSTOMIZE .env ────────────────────────────────────────────────────
section "Kustomize .env"
LDAP_BASE_DN="dc=$(echo "${DOMAIN}" | sed 's/\./,dc=/g')"

cat > "${NINEKUBE_DIR}/base/.env" <<EOF
DOMAIN=${DOMAIN}
MINIO_HOST=minio.${DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}
CLUSTER_EMAIL=${EMAIL}
EOF
ok "base/.env generated"

# ─── DONE ────────────────────────────────────────────────────────────────────────
hint "File: ${CONFIG_FILE}"
done_ok "config set"
