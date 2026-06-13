#!/bin/bash
source "$(dirname "$0")/helpers.sh"

header "APPLY CONFIG"

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

ADMIN_PASS=$(ask_value_constrained "Admin password" "$(config_get admin_password 'changeme')" 8 40)
config_set admin_password "$ADMIN_PASS"

# ─── AUTHENTIK ───────────────────────────────────────────────────────────────────
section "Authentik (SSO)"
AK_SECRET_KEY=$(ask_value "Authentik secret key" "$(config_get authentik_secret_key 'changeme')")
config_set authentik_secret_key "$AK_SECRET_KEY"

# ─── LDAP ────────────────────────────────────────────────────────────────────────
section "LDAP Service"
LDAP_PASS=$(ask_value "LDAP service password" "$(config_get ldap_password 'ldapservice-password')")
config_set ldap_password "$LDAP_PASS"

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
LDAP_DC=$(echo "${DOMAIN}" | tr '.' ',DC=')

cat > "${NINEKUBE_DIR}/base/.env" <<EOF
DOMAIN=${DOMAIN}
AUTHENTIK_URL=https://authentik.${DOMAIN}
AUTHENTIK_HOST=authentik.${DOMAIN}
MINIO_HOST=minio.${DOMAIN}
LDAP_HOST=authentik.${DOMAIN}
LDAP_PORT=389
LDAP_BASE_DN=DC=ldap,DC=${LDAP_DC}
LDAP_BIND_DN=cn=ldapservice,ou=users,DC=ldap,DC=${LDAP_DC}
AUTHENTIK_FOOTER=<a href="https://${DOMAIN}">Ninekube</a>
AUTHENTIK_BOOTSTRAP_EMAIL=${ADMIN_USER}@${DOMAIN}
CLUSTER_EMAIL=${EMAIL}
EOF
ok "base/.env generated"

# ─── DONE ────────────────────────────────────────────────────────────────────────
hint "File: ${CONFIG_FILE}"
done_ok "config applied"
