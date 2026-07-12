#!/bin/bash
source "$(dirname "$0")/helpers.sh"

NAMESPACE="nine"
DOMAIN=$(config_get domain 'nine.local')

header "POSTDEPLOY NINEGATE"

# --- WAIT FOR GLAUTH ---
info "waiting for glauth pod..."
if ! k8s_wait_pod "$NAMESPACE" "app.kubernetes.io/name=glauth" 60; then
  ko "glauth pod not ready in time"
  exit 1
fi
ok "glauth: pod running"

# --- WAIT FOR NINEGATE ---
info "waiting for ninegate pod..."
if ! k8s_wait_pod "$NAMESPACE" "app.kubernetes.io/name=ninegate" 120; then
  ko "ninegate pod not ready in time"
  exit 1
fi
ok "ninegate: pod running"

# --- LDAP SYNC (syncs users + sha256 passwords to glauth tables) ---
info "syncing LDAP users from ninegate..."
kubectl -n "$NAMESPACE" exec deployment/ninegate -- php bin/console app:ldap:sync 2>&1 | indent
ok "ldap sync"

# --- RESTART GLAUTH (plugin postgres needs fresh connection after sync) ---
info "restarting glauth..."
kubectl -n "$NAMESPACE" rollout restart deployment glauth 2>&1 | indent
kubectl -n "$NAMESPACE" rollout status deployment glauth --timeout=60s 2>&1 | indent
ok "glauth restarted"

done_ok "ninegate ready — access at https://ninegate.${DOMAIN}"
