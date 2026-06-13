#!/bin/bash
source "$(dirname "$0")/helpers.sh"

CERTMANAGER_VERSION="${CERTMANAGER_VERSION:-v1.17.1}"

if kubectl get ns cert-manager &>/dev/null; then
  ok "cert-manager: already installed"
  exit 0
fi

header "CERT-MANAGER"
info "cert-manager: installing ${CERTMANAGER_VERSION}..."
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERTMANAGER_VERSION}/cert-manager.yaml" 2>&1 | indent

dim "waiting for cert-manager pods..."
for i in $(seq 1 60); do
  READY=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -c " Running" || true)
  [ "$READY" -ge 3 ] && break
  sleep 2
done

done_ok "cert-manager installed"
