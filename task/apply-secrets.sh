#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
PREFIX="${ENV}"

if [ ! -f "$CONFIG_FILE" ]; then
  warn "no config found, using defaults"
  exit 0
fi

DOMAIN=$(config_get domain)
AUTHENTIK_SECRET_KEY=$(config_get authentik_secret_key)
ADMIN_USER=$(config_get admin_username)
ADMIN_PASS=$(config_get admin_password)
LDAP_PASS=$(config_get ldap_password)
PG_PASS=$(config_get pg_password)
MINIO_ROOT_USER=$(config_get minio_root_user 'minioroot')
MINIO_ROOT_PASS=$(config_get minio_root_password 'changeme')

header "APPLY SECRETS (${ENV})"

# ─── NAMESPACE ──────────────────────────────────────────────────────────────────
info "ensuring namespace nine exists..."
kubectl create namespace nine --dry-run=client -o yaml 2>&1 | kubectl apply -f - 2>&1 | indent

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# ─── AUTHENTIK SECRET ───────────────────────────────────────────────────────────
if [ -n "$AUTHENTIK_SECRET_KEY" ]; then
  info "patching authentik secret..."
  cat > "$TMPFILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${PREFIX}-authentik-secret
  namespace: nine
type: Opaque
stringData:
  AUTHENTIK_SECRET_KEY: "${AUTHENTIK_SECRET_KEY}"
  AUTHENTIK_POSTGRESQL__PASSWORD: "${PG_PASS}"
EOF
  kubectl apply -f "$TMPFILE" 2>&1 | indent
  ok "authentik secret: patched"
fi

# ─── POSTGRES SECRET ────────────────────────────────────────────────────────────
if [ -n "$PG_PASS" ]; then
  info "patching postgres secret..."
  cat > "$TMPFILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${PREFIX}-postgres-secret
  namespace: nine
type: Opaque
stringData:
  password: "${PG_PASS}"
EOF
  kubectl apply -f "$TMPFILE" 2>&1 | indent
  ok "postgres secret: patched"
fi

# ─── AUTHENTIK CONFIGMAP ────────────────────────────────────────────────────────
if [ -n "$ADMIN_PASS" ]; then
  info "patching authentik configmap..."
  cat > "$TMPFILE" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PREFIX}-authentik-config
  namespace: nine
data:
  AUTHENTIK_BOOTSTRAP_PASSWORD: "${ADMIN_PASS}"
  AUTHENTIK_BOOTSTRAP_EMAIL: "${ADMIN_USER}@${DOMAIN}"
EOF
  kubectl apply -f "$TMPFILE" 2>&1 | indent
  ok "authentik configmap: patched"
fi

# ─── MINIO SECRET ───────────────────────────────────────────────────────────────
info "creating minio secret..."
cat > "$TMPFILE" <<EOF
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
kubectl apply -f "$TMPFILE" 2>&1 | indent
ok "minio secret: created"

# ─── SHARED CONFIGMAP ───────────────────────────────────────────────────────────
if [ -n "$DOMAIN" ]; then
  LDAP_DC=$(echo "${DOMAIN}" | tr '.' ',DC=')
  info "patching shared configmap..."
  cat > "$TMPFILE" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PREFIX}-nine-config
  namespace: nine
data:
  DOMAIN: "${DOMAIN}"
  AUTHENTIK_URL: "https://authentik.${DOMAIN}"
  LDAP_HOST: "authentik.${DOMAIN}"
  LDAP_BIND_DN: "cn=ldapservice,ou=users,DC=ldap,DC=${LDAP_DC}"
  LDAP_BASE_DN: "DC=ldap,DC=${LDAP_DC}"
  MINIO_HOST: "minio.${DOMAIN}"
EOF
  kubectl apply -f "$TMPFILE" 2>&1 | indent
  ok "shared configmap: patched"
fi

# ─── SHARED SECRETS ─────────────────────────────────────────────────────────────
if [ -n "$LDAP_PASS" ]; then
  info "patching shared secrets..."
  cat > "$TMPFILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${PREFIX}-nine-secrets
  namespace: nine
type: Opaque
stringData:
  LDAP_BIND_PASSWORD: "${LDAP_PASS}"
  MINIO_ROOT_USER: "${MINIO_ROOT_USER}"
  MINIO_ROOT_PASSWORD: "${MINIO_ROOT_PASS}"
EOF
  kubectl apply -f "$TMPFILE" 2>&1 | indent
  ok "shared secrets: patched"
fi

# ─── RESTART PODS ────────────────────────────────────────────────────────────────
if kubectl get deploy ${PREFIX}-authentik-server -n nine &>/dev/null 2>&1; then
  info "restarting pods..."
  kubectl rollout restart deployment ${PREFIX}-authentik-server -n nine 2>&1 | indent
  kubectl rollout restart deployment ${PREFIX}-authentik-worker -n nine 2>&1 | indent
  kubectl rollout restart statefulset ${PREFIX}-postgres -n nine 2>&1 | indent
  kubectl rollout restart deployment ${PREFIX}-minio -n nine 2>&1 | indent
  ok "pods: restarting"
fi

done_ok "secrets applied"
