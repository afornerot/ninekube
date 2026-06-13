#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
PREFIX="${ENV}"

header "APPLY CERT"

DOMAIN=$(config_get domain 'nine.local')
CERT_TYPE=$(config_get cert_type 'self-signed')

if [ "$CERT_TYPE" = "letsencrypt-staging" ] || [ "$CERT_TYPE" = "letsencrypt-prod" ]; then
  EMAIL=$(config_get email "admin@${DOMAIN}")
fi

section "ClusterIssuer"
info "domain: ${DOMAIN}"
info "type: ${CERT_TYPE}"

ISSUER=""
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

if [ "$CERT_TYPE" = "self-signed" ]; then
  info "creating self-signed ClusterIssuer..."
  cat > "$TMPFILE" <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
  kubectl apply -f "$TMPFILE" 2>&1 | indent
  ISSUER="selfsigned-issuer"

elif [ "$CERT_TYPE" = "letsencrypt-staging" ] || [ "$CERT_TYPE" = "letsencrypt-prod" ]; then
  SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
  [ "$CERT_TYPE" = "letsencrypt-prod" ] && SERVER="https://acme-v02.api.letsencrypt.org/directory"
  info "creating ${CERT_TYPE} ClusterIssuer..."
  cat > "$TMPFILE" <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CERT_TYPE}
spec:
  acme:
    server: ${SERVER}
    email: ${EMAIL}
    privateKeySecretRef:
      name: ${CERT_TYPE}-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
EOF
  kubectl apply -f "$TMPFILE" 2>&1 | indent
  ISSUER="$CERT_TYPE"

else
  ko "unknown type: ${CERT_TYPE}"
  exit 1
fi

section "Ingresses"
info "updating ingresses with domain ${DOMAIN}..."
for INGRESS in ${PREFIX}-authentik ${PREFIX}-minio; do
  SHORT="${INGRESS#${PREFIX}-}"
  kubectl patch ingress "$INGRESS" -n nine --type='json' -p "[
    {\"op\": \"replace\", \"path\": \"/spec/rules/0/host\", \"value\": \"${SHORT}.${DOMAIN}\"},
    {\"op\": \"replace\", \"path\": \"/spec/tls/0/hosts/0\", \"value\": \"${SHORT}.${DOMAIN}\"},
    {\"op\": \"replace\", \"path\": \"/metadata/annotations/cert-manager.io~1cluster-issuer\", \"value\": \"${ISSUER}\"}
  ]" 2>&1 | indent
  ok "ingress ${INGRESS}: ${SHORT}.${DOMAIN}"
done

section "Certificates"
info "waiting for certificates..."
sleep 5
kubectl get certificate -n nine 2>/dev/null | indent

hint "add to /etc/hosts:"
hint "  $(hostname -I | awk '{print $1}') authentik.${DOMAIN} minio.${DOMAIN}"
done_ok "certificates applied"
