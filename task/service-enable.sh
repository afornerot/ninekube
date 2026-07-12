#!/bin/bash
source "$(dirname "$0")/helpers.sh"

SERVICE="${1:?Usage: service-enable SERVICE=<service>}"
SERVICES_DIR="${NINEKUBE_DIR}/services"
SERVICE_DIR="${SERVICES_DIR}/${SERVICE}"
ENABLED_DIR="${BASE_DIR}/enabled-services"

header "ENABLE SERVICE: ${SERVICE}"

# Validate service exists
if [ ! -d "$SERVICE_DIR" ]; then
  done_ko "Service '${SERVICE}' not found in ${SERVICES_DIR}"
  exit 1
fi

mkdir -p "${ENABLED_DIR}"

# Check if already enabled
if [ -L "${ENABLED_DIR}/${SERVICE}" ]; then
  done_warn "Service '${SERVICE}' is already enabled"
  exit 0
fi

# Create symlink
info "creating symlink..."
ln -s "../../services/${SERVICE}" "${ENABLED_DIR}/${SERVICE}"
ok "symlink created"

# Regenerate kustomization
info "regenerating kustomization..."
generate_enabled_kustomization
ok "kustomization regenerated"

done_ok "Service '${SERVICE}' enabled"
