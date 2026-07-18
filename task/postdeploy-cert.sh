#!/bin/bash
source "$(dirname "$0")/helpers.sh"

DOMAIN=$(config_get domain 'nine.local')

header "POSTDEPLOY CERT"

# ─── PATCH INGRESSES WITH DOMAIN + ISSUER ──────────────────────────────────────
section "Ingresses"
info "updating ingresses with domain ${DOMAIN}..."

CERT_TYPE=$(config_get cert_type 'self-signed')
if [ "$CERT_TYPE" = "self-signed" ]; then
  ISSUER="selfsigned-issuer"
else
  ISSUER="$CERT_TYPE"
fi

INGRESSES="dex rustfs ninegate"
HOSTS="dex.${DOMAIN} rustfs.${DOMAIN} ninegate.${DOMAIN}"

for service_dir in "${NINEKUBE_DIR}/services"/*/; do
  [ ! -d "$service_dir" ] && continue
  service=$(basename "$service_dir")
  if [ -L "${BASE_DIR}/${service}" ]; then
    INGRESSES="${INGRESSES} ${service}"
    HOSTS="${HOSTS} ${service}.${DOMAIN}"
  fi
done

for INGRESS in $INGRESSES; do
  if kubectl get ingress "$INGRESS" -n nine >/dev/null 2>&1; then
    kubectl patch ingress "$INGRESS" -n nine --type='json' -p "[
      {\"op\": \"replace\", \"path\": \"/spec/rules/0/host\", \"value\": \"${INGRESS}.${DOMAIN}\"},
      {\"op\": \"replace\", \"path\": \"/spec/tls/0/hosts/0\", \"value\": \"${INGRESS}.${DOMAIN}\"},
      {\"op\": \"replace\", \"path\": \"/metadata/annotations/cert-manager.io~1cluster-issuer\", \"value\": \"${ISSUER}\"}
    ]" 2>&1 | indent
    ok "ingress ${INGRESS}: ${INGRESS}.${DOMAIN}"
  else
    warn "ingress ${INGRESS} not found, skipping"
  fi
done

# ─── PATCH IngressRouteTCP (dex TLS passthrough) ──────────────────────────────
info "patching dex IngressRouteTCP..."
if kubectl get ingressroutetcp.traefik.io dex -n nine >/dev/null 2>&1; then
  PATCH=$(jq -n --arg domain "$DOMAIN" '[{"op": "replace", "path": "/spec/routes/0/match", "value": ("HostSNI(`dex." + $domain + "`)")}]')
  kubectl patch ingressroutetcp.traefik.io dex -n nine --type='json' -p "$PATCH" 2>&1 | indent
  ok "ingressroutetcp dex: dex.${DOMAIN}"
else
  warn "ingressroutetcp dex not found, skipping"
fi

# ─── CERTIFICATES ──────────────────────────────────────────────────────────────
section "Certificates"
info "waiting for certificates..."
sleep 5
kubectl get certificate -n nine 2>/dev/null | indent

hint "add to /etc/hosts:"
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
for host in $HOSTS; do
  hint "  ${NODE_IP} ${host}"
done

done_ok "cert applied"
