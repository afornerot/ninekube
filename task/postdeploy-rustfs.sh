#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"

RUSTFS_ROOT_USER=$(config_get rustfs_root_user 'rustfsadmin')
RUSTFS_ROOT_PASS=$(config_get rustfs_root_password 'changeme')

header "POSTDEPLOY RUSTFS"

# ─── WAIT FOR RUSTFS ───────────────────────────────────────────────────────────
info "waiting for rustfs pod..."
if ! k8s_wait_pod "nine" "app.kubernetes.io/name=rustfs" 60; then
  ko "rustfs: not running"
  exit 1
fi
ok "rustfs: pod running"

# ─── WAIT FOR NINEGATE ────────────────────────────────────────────────────────
info "waiting for ninegate pod..."
if ! k8s_wait_pod "nine" "app.kubernetes.io/name=ninegate" 60; then
  ko "ninegate: not running"
  exit 1
fi
ok "ninegate: pod running"

# ─── CREATE BUCKET FROM CLUSTER ──────────────────────────────────────────────
info "creating ninegate-uploads bucket..."
kubectl -n nine exec deployment/ninegate -- php -r "
require '/app/vendor/autoload.php';
\$client = new \Aws\S3\S3Client([
    'version' => 'latest',
    'region' => 'us-east-1',
    'endpoint' => 'http://rustfs:9000',
    'use_path_style_endpoint' => true,
    'credentials' => ['key' => '${RUSTFS_ROOT_USER}', 'secret' => '${RUSTFS_ROOT_PASS}'],
]);
try {
    \$client->headBucket(['Bucket' => 'ninegate-uploads']);
} catch (\Exception \$e) {
    \$client->createBucket(['Bucket' => 'ninegate-uploads']);
}
echo 'OK' . PHP_EOL;
" 2>&1 | indent
ok "bucket: ninegate-uploads"

# ─── VERIFY BUCKET ────────────────────────────────────────────────────────────
info "verifying bucket..."
kubectl -n nine exec deployment/ninegate -- php -r "
require '/app/vendor/autoload.php';
\$client = new \Aws\S3\S3Client([
    'version' => 'latest',
    'region' => 'us-east-1',
    'endpoint' => 'http://rustfs:9000',
    'use_path_style_endpoint' => true,
    'credentials' => ['key' => '${RUSTFS_ROOT_USER}', 'secret' => '${RUSTFS_ROOT_PASS}'],
]);
try {
    \$client->headBucket(['Bucket' => 'ninegate-uploads']);
    echo 'OK' . PHP_EOL;
} catch (\Exception \$e) {
    echo 'ERROR: ' . \$e->getMessage() . PHP_EOL;
    exit(1);
}
" 2>&1 | indent
ok "bucket: verified"

done_ok "rustfs configured"
