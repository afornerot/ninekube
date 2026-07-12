#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
PREFIX="${ENV}"

DOMAIN=$(config_get domain 'nine.local')
CERT_TYPE=$(config_get cert_type 'self-signed')

if [ "$CERT_TYPE" = "letsencrypt-staging" ] || [ "$CERT_TYPE" = "letsencrypt-prod" ]; then
  EMAIL=$(config_get email "admin@${DOMAIN}")
fi

header "PREDEPLOY CERT"

# ─── CLUSTERISSUER ──────────────────────────────────────────────────────────
section "ClusterIssuer"
info "domain: ${DOMAIN}"
info "type: ${CERT_TYPE}"

if [ "$CERT_TYPE" = "self-signed" ]; then
  info "creating self-signed ClusterIssuer..."
  apply_manifest <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
elif [ "$CERT_TYPE" = "letsencrypt-staging" ] || [ "$CERT_TYPE" = "letsencrypt-prod" ]; then
  SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
  [ "$CERT_TYPE" = "letsencrypt-prod" ] && SERVER="https://acme-v02.api.letsencrypt.org/directory"
  info "creating ${CERT_TYPE} ClusterIssuer..."
  apply_manifest <<EOF
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
else
  ko "unknown type: ${CERT_TYPE}"
  exit 1
fi

done_ok "cert predeploy"
