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
NODE_IP=$(hostname -I | awk '{print $1}')
kubectl -n nine patch deployment ninegate --type='json' -p "[
  {\"op\": \"add\", \"path\": \"/spec/template/spec/hostAliases\", \"value\": [{\"ip\": \"${NODE_IP}\", \"hostnames\": [\"dex.${DOMAIN}\", \"ninegate.${DOMAIN}\"]}]}
]" 2>&1 | indent

done_ok "${ENV} overlay deployed"
