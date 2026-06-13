#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
NAMESPACE="nine"
SERVICE_NAME="tinyfilemanager"
IMAGE="tinyfilemanager/tinyfilemanager:latest"
DOMAIN=$(config_get domain 'nine.local')

header "APPLY TINYFILEMANAGER"

# ─── DETECT DEPLOYMENT NAME ────────────────────────────────────────────────
DEPLOY_NAME=$(k8s_detect_deploy "$NAMESPACE" "$SERVICE_NAME")
if [ -z "$DEPLOY_NAME" ]; then
  ko "No deployment found for ${SERVICE_NAME}"
  exit 1
fi
info "detected deployment: ${DEPLOY_NAME}"

# Read the configmap name from the deployment spec (kustomize may or may not rename it)
CONFIGMAP_NAME=$(kubectl get deploy "$DEPLOY_NAME" -n ${NAMESPACE} \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}' 2>/dev/null)
if [ -z "$CONFIGMAP_NAME" ]; then
  CONFIGMAP_NAME="${SERVICE_NAME}-config"
fi

# ─── EXTRACT INDEX.PHP FROM IMAGE ──────────────────────────────────────────
info "extracting index.php from image..."
TMPDIR=$(mktemp -d)
docker run --rm --entrypoint="/bin/sh" "${IMAGE}" -c "cat /var/www/html/index.php" > "${TMPDIR}/index.php" 2>/dev/null

if [ ! -s "${TMPDIR}/index.php" ]; then
  ko "Failed to extract index.php from image"
  rm -rf "${TMPDIR}"
  exit 1
fi
ok "extracted ($(wc -c < "${TMPDIR}/index.php") bytes)"

# ─── PATCH CONFIG (auth disabled, root path, CDN assets) ───────────────────
info "patching config..."

cat > "${TMPDIR}/patch.pl" <<'PLEOF'
#!/usr/bin/perl -i -0777
use strict;
my $file = $ARGV[0];
open(my $fh, '<', $file) or die "Cannot open $file: $!";
my $content = do { local $/; <$fh> };
close($fh);
$content =~ s/\$use_auth\s*=\s*(true|false);/\$use_auth = false;/;
$content =~ s/\$root_path\s*=\s*\$_SERVER\['DOCUMENT_ROOT'\];/\$root_path = '\/var\/www\/html\/data';/;
my $external = <<'EXTERNALS';
$external = array(
    'css-bootstrap' => '<link href="https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/5.3.3/css/bootstrap.min.css" rel="stylesheet">',
    'css-dropzone' => '<link href="https://cdnjs.cloudflare.com/ajax/libs/dropzone/5.9.3/min/dropzone.min.css" rel="stylesheet">',
    'css-font-awesome' => '<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" crossorigin="anonymous">',
    'css-highlightjs' => '<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/' . $highlightjs_style . '.min.css">',
    'js-ace' => '<script src="https://cdnjs.cloudflare.com/ajax/libs/ace/1.32.6/ace.js"></script>',
    'js-bootstrap' => '<script src="https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/5.3.3/js/bootstrap.bundle.min.js"></script>',
    'js-dropzone' => '<script src="https://cdnjs.cloudflare.com/ajax/libs/dropzone/5.9.3/min/dropzone.min.js"></script>',
    'js-jquery' => '<script src="https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js"></script>',
    'js-jquery-datatables' => '<script src="https://cdnjs.cloudflare.com/ajax/libs/datatables/1.10.21/js/dataTables.min.js"></script>',
    'js-highlightjs' => '<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>',
);
EXTERNALS
$content =~ s/\$external\s*=\s*array\(.*?\);/$external/s;
open(my $out, '>', $file) or die "Cannot write $file: $!";
print $out $content;
close($out);
PLEOF

perl "${TMPDIR}/patch.pl" "${TMPDIR}/index.php"
ok "config patched"

# ─── APPLY CONFIGMAP (idempotent) ──────────────────────────────────────────
info "applying ConfigMap..."
if k8s_apply_configmap "$NAMESPACE" "$CONFIGMAP_NAME" "index.php" "${TMPDIR}/index.php"; then
  info "ConfigMap changed, deleting pod to apply..."
  kubectl delete pod -n ${NAMESPACE} -l app.kubernetes.io/name=${SERVICE_NAME} 2>&1 | indent
  if k8s_wait_pod "${NAMESPACE}" "app.kubernetes.io/name=tinyfilemanager" 60; then
    ok "pod restarted"
  else
    ko "pod did not restart in time"
    exit 1
  fi
else
  dim "ConfigMap unchanged, skipping restart"
fi

# ─── CLEANUP ────────────────────────────────────────────────────────────────
rm -rf "${TMPDIR}"

done_ok "tinyfilemanager configured — access at https://files.${DOMAIN}"
