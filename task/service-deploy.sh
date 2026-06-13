#!/bin/bash
source "$(dirname "$0")/helpers.sh"

SERVICE="${1:?Usage: service-deploy SERVICE=<service> [ENV=<env>]}"
ENV="${2:-dev}"
SERVICES_DIR="${NINEKUBE_DIR}/services"
SERVICE_DIR="${SERVICES_DIR}/${SERVICE}"

header "DEPLOY SERVICE: ${SERVICE}"

# Validate service exists
if [ ! -d "$SERVICE_DIR" ]; then
  done_ko "Service '${SERVICE}' not found in ${SERVICES_DIR}"
  exit 1
fi

# Check if enabled
if [ ! -L "${BASE_DIR}/${SERVICE}" ]; then
  warn "Service '${SERVICE}' is not enabled yet, enabling it first..."
  bash "$(dirname "$0")/service-enable.sh" "$SERVICE"
fi

# Deploy via overlay (consistent naming with prefix)
info "deploying ${ENV} overlay (includes ${SERVICE})..."
kubectl apply -k "overlays/${ENV}/" 2>&1 | indent
ok "overlay applied"

# Run apply script if present
if [ -x "task/apply-${SERVICE}.sh" ]; then
  info "running apply-${SERVICE}.sh..."
  bash "task/apply-${SERVICE}.sh" "$ENV"
fi

done_ok "Service '${SERVICE}' deployed"
