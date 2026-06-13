#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"

header "DEPLOY ${ENV^^}"

generate_env
info "generated base/.env from config"

kubectl apply -k "overlays/${ENV}/" 2>&1 | indent
done_ok "${ENV} overlay deployed"
