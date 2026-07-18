#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"

header "DEPLOY ${ENV^^}"

generate_env
info "generated base/.env from config"

# Ensure enabled-services kustomization is up to date
generate_enabled_kustomization

kubectl apply -k "overlays/${ENV}/" 2>&1 | indent

# Patch hostAliases so ninegate pod can resolve dex.nine.local (needed for OIDC)
DOMAIN=$(config_get domain 'nine.local')
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
kubectl -n nine patch deployment ninegate --type='json' -p "[
  {\"op\": \"add\", \"path\": \"/spec/template/spec/hostAliases\", \"value\": [{\"ip\": \"${NODE_IP}\", \"hostnames\": [\"dex.${DOMAIN}\", \"ninegate.${DOMAIN}\"]}]}
]" 2>&1 | indent

# Patch hostAliases so nextcloud pod can resolve dex.nine.local (needed for OIDC)
if kubectl get deployment nextcloud -n nine >/dev/null 2>&1; then
  kubectl -n nine patch deployment nextcloud --type='json' -p "[
    {\"op\": \"add\", \"path\": \"/spec/template/spec/hostAliases\", \"value\": [{\"ip\": \"${NODE_IP}\", \"hostnames\": [\"dex.${DOMAIN}\", \"nextcloud.${DOMAIN}\"]}]}
  ]" 2>&1 | indent
fi

done_ok "${ENV} overlay deployed"
