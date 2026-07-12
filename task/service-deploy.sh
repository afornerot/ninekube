#!/bin/bash
source "$(dirname "$0")/helpers.sh"

SERVICE="${1:?Usage: service-deploy SERVICE=<service> [ENV=<env>]}"
ENV="${2:-dev}"
SERVICES_DIR="${NINEKUBE_DIR}/services"
SERVICE_DIR="${SERVICES_DIR}/${SERVICE}"
ENABLED_DIR="${BASE_DIR}/enabled-services"

header "DEPLOY SERVICE: ${SERVICE}"

# Validate service exists
if [ ! -d "$SERVICE_DIR" ]; then
  done_ko "Service '${SERVICE}' not found in ${SERVICES_DIR}"
  exit 1
fi

# Check if enabled
if [ ! -L "${ENABLED_DIR}/${SERVICE}" ]; then
  warn "Service '${SERVICE}' is not enabled yet, enabling it first..."
  bash "$(dirname "$0")/service-enable.sh" "$SERVICE"
fi

# 1. Predeploy
if [ -x "task/predeploy-${SERVICE}.sh" ]; then
  section "Predeploy ${SERVICE}"
  bash "$(dirname "$0")/predeploy-${SERVICE}.sh" "$ENV"
fi

# 2. Deploy via overlay
section "Deploy ${SERVICE}"
info "deploying ${ENV} overlay (includes ${SERVICE})..."
kubectl apply -k "overlays/${ENV}/" 2>&1 | indent
ok "overlay applied"

# 3. Postdeploy
if [ -x "task/postdeploy-${SERVICE}.sh" ]; then
  section "Postdeploy ${SERVICE}"
  bash "$(dirname "$0")/postdeploy-${SERVICE}.sh" "$ENV"
fi

done_ok "Service '${SERVICE}' deployed"
