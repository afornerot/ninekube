#!/bin/bash
source "$(dirname "$0")/helpers.sh"

NAMESPACE="nine"
SERVICE_NAME="nextcloud"
DOMAIN=$(config_get domain 'nine.local')
NEXTCLOUD_CLIENT_SECRET=$(config_get dex_nextcloud_client_secret '')
RUSTFS_USER=$(config_get rustfs_root_user 'rustfsadmin')
RUSTFS_PASS=$(config_get rustfs_root_password 'changeme')
PG_USER=$(config_get postgres_username 'postgres')

header "POSTDEPLOY NEXTCLOUD"

# ─── ENSURE NEXTCLOUD DATABASE EXISTS ────────────────────────────────────────
section "Database"
PG_POD=$(k8s_pod "$NAMESPACE" "app.kubernetes.io/name=postgres")
if [ -n "$PG_POD" ]; then
  DB_EXISTS=$(kubectl exec -n "$NAMESPACE" "$PG_POD" -- \
    psql -U "${PG_USER}" -tAc "SELECT 1 FROM pg_database WHERE datname='nextcloud'" 2>/dev/null || echo "")
  if [ "$DB_EXISTS" != "1" ]; then
    info "creating nextcloud database..."
    kubectl exec -n "$NAMESPACE" "$PG_POD" -- \
      psql -U "${PG_USER}" -c "CREATE DATABASE nextcloud;" 2>&1 | indent
    ok "nextcloud database created"
  else
    dim "nextcloud database: already exists"
  fi
fi

# ─── CREATE RUSTFS BUCKET ───────────────────────────────────────────────────
section "Storage"
info "ensuring nextcloud-data bucket exists in rustfs..."
kubectl -n "$NAMESPACE" exec deployment/ninegate -- php -r "
require '/app/vendor/autoload.php';
\$client = new \Aws\S3\S3Client([
    'version' => 'latest',
    'region' => 'us-east-1',
    'endpoint' => 'http://rustfs:9000',
    'use_path_style_endpoint' => true,
    'credentials' => ['key' => '${RUSTFS_USER}', 'secret' => '${RUSTFS_PASS}'],
]);
try {
    \$client->headBucket(['Bucket' => 'nextcloud-data']);
} catch (\Exception \$e) {
    \$client->createBucket(['Bucket' => 'nextcloud-data']);
}
echo 'OK' . PHP_EOL;
" 2>&1 | indent
ok "bucket: nextcloud-data"

# ─── WAIT FOR NEXTCLOUD POD ──────────────────────────────────────────────────
POD=$(k8s_ensure_pod "$NAMESPACE" "$SERVICE_NAME" 120)
if [ -z "$POD" ]; then
  ko "nextcloud: not running"
  exit 1
fi
ok "nextcloud: pod running"

# ─── WAIT FOR NEXTCLOUD TO BE READY ────────────────────────────────────────
info "waiting for Nextcloud to initialize..."
if k8s_wait_ready "$NAMESPACE" "$SERVICE_NAME" "Nextcloud init" 120 \
  -- bash -c "test -f /var/www/html/config/config.php && php occ status 2>/dev/null | grep -q 'installed: true'"; then
  ok "nextcloud: initialized"
else
  ko "nextcloud: initialization timeout"
  exit 1
fi

# ─── INSTALL PLUGINS ────────────────────────────────────────────────────────
section "Plugins"

for plugin in calendar oidc_login groupfolders; do
  if k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ app:list 2>/dev/null | grep -q "$plugin"; then
    dim "${plugin}: already installed"
  else
    info "installing ${plugin}..."
    k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ app:install "$plugin" 2>&1 | indent
    ok "${plugin}: installed"
  fi
done

# ─── CONFIGURE OIDC ─────────────────────────────────────────────────────────
section "OIDC Configuration"

OIDC_CONFIGURED=$(k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:get oidc_login 2>/dev/null | grep -c "provider-url" || echo "0")
if [ "$OIDC_CONFIGURED" -gt 0 ]; then
  dim "OIDC: already configured"
else
  info "configuring OIDC login with Dex..."

  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login provider-url --value="https://dex.${DOMAIN}" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login client-id --value="nextcloud" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login client-secret --value="${NEXTCLOUD_CLIENT_SECRET}" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login redirect-url --value="https://cloud.${DOMAIN}/index.php/login/via oidc_login/" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login discovery-url --value="https://dex.${DOMAIN}/.well-known/openid-configuration" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login auto-provision --value="1" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login uid_key --value="sub" 2>&1 | indent
  ok "OIDC: configured"
fi

# ─── CONFIGURE TRUSTED DOMAIN ───────────────────────────────────────────────
section "Trusted Domain"

TRUSTED_DOMAIN=$(k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:system:get trusted_domains 2>/dev/null | grep -c "cloud.${DOMAIN}" || echo "0")
if [ "$TRUSTED_DOMAIN" -gt 0 ]; then
  dim "trusted domain: already configured"
else
  info "adding trusted domain..."
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:system:set trusted_domains 1 --value="cloud.${DOMAIN}" 2>&1 | indent
  ok "trusted domain added"
fi

done_ok "nextcloud configured — access at https://cloud.${DOMAIN}"
