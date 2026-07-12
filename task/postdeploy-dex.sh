#!/bin/bash
source "$(dirname "$0")/helpers.sh"

DOMAIN=$(config_get domain 'nine.local')
NAMESPACE="nine"

header "POSTDEPLOY DEX"

# --- WAIT FOR POD ---
info "waiting for dex pod..."
if ! k8s_wait_pod "$NAMESPACE" "app.kubernetes.io/name=dex" 120; then
  ko "dex pod not ready in time"
  exit 1
fi
ok "pod running"

done_ok "dex ready — access at https://dex.${DOMAIN}"
