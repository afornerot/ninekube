#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
DOMAIN=$(config_get domain 'nine.local')
ADMIN_PASS=$(config_get admin_password 'changeme')
PG_USER=$(config_get postgres_username 'postgres')
PG_PASS=$(config_get pg_password 'changeme')

header "PREDEPLOY NINEGATE"

# --- NINEGATE SECRET ---
info "creating ninegate secret..."
NINEGATE_APP_SECRET=$(config_get ninegate_app_secret '')
if [ -z "$NINEGATE_APP_SECRET" ]; then
  NINEGATE_APP_SECRET=$(openssl rand -hex 32)
  config_set ninegate_app_secret "$NINEGATE_APP_SECRET"
  info "generated ninegate app secret"
fi

NINEGATE_OIDC_CLIENT_SECRET=$(config_get dex_ninegate_client_secret '')
if [ -z "$NINEGATE_OIDC_CLIENT_SECRET" ]; then
  NINEGATE_OIDC_CLIENT_SECRET=$(openssl rand -base64 32)
  config_set dex_ninegate_client_secret "$NINEGATE_OIDC_CLIENT_SECRET"
  info "generated ninegate oidc client secret"
fi

DATABASE_URL="postgresql://${PG_USER}:${PG_PASS}@postgres:5432/ninegate?serverVersion=16"

LDAP_BASE_DN="dc=$(echo "${DOMAIN}" | sed 's/\./,dc=/g')"

RUSTFS_USER=$(config_get rustfs_root_user 'rustfsadmin')
RUSTFS_PASS=$(config_get rustfs_root_password 'changeme')

apply_manifest <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ninegate-secret
  namespace: nine
  labels:
    app.kubernetes.io/name: ninegate
    app.kubernetes.io/part-of: ninekube
type: Opaque
stringData:
  app-secret: "${NINEGATE_APP_SECRET}"
  app-admin-password: "${ADMIN_PASS}"
  database-url: "${DATABASE_URL}"
  ldap-base: "${LDAP_BASE_DN}"
  oidc-client-secret: "${NINEGATE_OIDC_CLIENT_SECRET}"
  default-uri: "https://ninegate.${DOMAIN}"
  oidc-issuer: "https://dex.${DOMAIN}"
  oidc-redirect-uri: "https://ninegate.${DOMAIN}/callback"
  storage-dsn: "s3://ninegate-uploads"
  s3-endpoint: "http://rustfs:9000"
  s3-bucket: "ninegate-uploads"
  s3-access-key: "${RUSTFS_USER}"
  s3-secret-key: "${RUSTFS_PASS}"
  s3-region: "us-east-1"
EOF
ok "ninegate secret"

# --- GLAUTH CONFIGMAP ---
info "creating glauth config..."
apply_manifest <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ninegate-glauth-config
  namespace: nine
  labels:
    app.kubernetes.io/name: glauth
    app.kubernetes.io/part-of: ninekube
    app.kubernetes.io/component: ninegate
data:
  config.cfg: |
    [backend]
      datastore = "plugin"
      plugin = "/app/postgres.so"
      pluginhandler = "NewPostgresHandler"
      database = "host=postgres port=5432 user=${PG_USER} password=${PG_PASS} dbname=ninegate sslmode=disable"
      baseDN = "${LDAP_BASE_DN}"

    [ldap]
      enabled = true
      listen = "0.0.0.0:3893"
      tls = false

    [ldaps]
      enabled = true
      listen = "0.0.0.0:636"
      tls = true
      cert = "/etc/glauth/tls/tls.crt"
      key = "/etc/glauth/tls/tls.key"

    [behaviors]
      IgnoreCapabilities = true
      LimitFailedBinds = true
      NumberOfFailedBinds = 3
      PeriodOfFailedBinds = 10
      BlockFailedBindsFor = 60
      PruneSourceTableEvery = 600
      PruneSourcesOlderThan = 600
EOF
ok "glauth config"

# --- GLAUTH TLS SECRET ---
info "creating glauth tls secret..."
TLS_DIR=$(mktemp -d)
if ! kubectl get secret glauth-tls -n nine >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -keyout "${TLS_DIR}/tls.key" -out "${TLS_DIR}/tls.crt" \
    -days 3650 -nodes -subj "/CN=glauth.${DOMAIN}" 2>/dev/null
  kubectl create secret tls glauth-tls \
    --namespace=nine \
    --cert="${TLS_DIR}/tls.crt" \
    --key="${TLS_DIR}/tls.key" \
    --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - 2>&1 | indent
  ok "glauth-tls secret"
else
  info "glauth-tls secret already exists"
fi
rm -rf "${TLS_DIR}"

done_ok "ninegate predeploy"
