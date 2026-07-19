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

# ─── INSTALL NEXTCLOUD ──────────────────────────────────────────────────────
section "Installation"
INSTALLED=$(k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ status 2>/dev/null | grep "installed:" | awk '{print $NF}')
if [ "$INSTALLED" = "true" ]; then
  dim "nextcloud: already installed"
else
  info "installing Nextcloud..."
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ maintenance:install \
    --admin-user admin --admin-pass changeme \
    --database pgsql --database-name nextcloud \
    --database-host postgres --database-port 5432 \
    --database-user "${PG_USER}" --database-pass "$(config_get pg_password 'changeme')" 2>&1 | indent
  ok "nextcloud: installed"
fi

# ─── CONFIGURE S3 STORAGE ───────────────────────────────────────────────────
section "S3 Storage"
S3_CONFIGURED=$(k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:system:get objectstore 2>/dev/null | grep -c "S3" || true)
if [ "$S3_CONFIGURED" -gt 0 ] 2>/dev/null; then
  dim "S3: already configured"
else
  info "configuring S3 storage with RustFS..."
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:system:set objectstore --value '{"class":"\OC\Files\ObjectStore\S3","arguments":{"bucket":"nextcloud-data","region":"us-east-1","hostname":"rustfs","port":9000,"key":"${RUSTFS_USER}","secret":"${RUSTFS_PASS}","use_path_style":true,"ssl":false}}' 2>&1 | indent
  ok "S3: configured"
fi

# ─── ENABLE PLUGINS ──────────────────────────────────────────────────────────
section "Plugins"
for plugin in calendar oidc_login; do
  if k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ app:list 2>/dev/null | grep -q "$plugin"; then
    dim "${plugin}: already enabled"
  else
    info "enabling ${plugin}..."
    k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ app:enable "$plugin" 2>&1 | indent
    ok "${plugin}: enabled"
  fi
done

# ─── CONFIGURE OIDC ─────────────────────────────────────────────────────────
section "OIDC Configuration"
OIDC_CONFIGURED=$(k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:app:get oidc_login provider-url 2>/dev/null | grep -c "dex" || true)
if [ "$OIDC_CONFIGURED" -gt 0 ] 2>/dev/null; then
  dim "OIDC: already configured"
else
  info "configuring OIDC login with Dex..."
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:app:set oidc_login provider-url --value "https://dex.${DOMAIN}" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:app:set oidc_login client-id --value "nextcloud" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:app:set oidc_login client-secret --value "${NEXTCLOUD_CLIENT_SECRET}" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:app:set oidc_login redirect-url --value "https://nextcloud.${DOMAIN}/index.php/login/via oidc_login/" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:app:set oidc_login discovery-url --value "https://dex.${DOMAIN}/.well-known/openid-configuration" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:app:set oidc_login auto-provision --value "1" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:app:set oidc_login uid_key --value "sub" 2>&1 | indent
  ok "OIDC: configured"
fi

# ─── CONFIGURE TRUSTED DOMAIN ───────────────────────────────────────────────
section "Trusted Domain"
TRUSTED_DOMAIN=$(k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:system:get trusted_domains 1 2>/dev/null | grep -c "nextcloud.${DOMAIN}" || true)
if [ "$TRUSTED_DOMAIN" -gt 0 ] 2>/dev/null; then
  dim "trusted domain: already configured"
else
  info "adding trusted domain..."
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" php occ config:system:set trusted_domains 1 --value "nextcloud.${DOMAIN}" 2>&1 | indent
  ok "trusted domain added"
fi

done_ok "nextcloud configured — access at https://nextcloud.${DOMAIN}"
