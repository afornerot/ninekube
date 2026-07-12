#!/bin/bash
source "$(dirname "$0")/helpers.sh"

SERVICE="${1:?Usage: service-disable SERVICE=<service>}"
ENABLED_DIR="${BASE_DIR}/enabled-services"

header "DISABLE SERVICE: ${SERVICE}"

# Check if enabled
if [ ! -L "${ENABLED_DIR}/${SERVICE}" ]; then
  done_warn "Service '${SERVICE}' is not enabled"
  exit 0
fi

# Remove symlink
info "removing symlink..."
rm -f "${ENABLED_DIR}/${SERVICE}"
ok "symlink removed"

# Regenerate kustomization
info "regenerating kustomization..."
generate_enabled_kustomization
ok "kustomization regenerated"

done_ok "Service '${SERVICE}' disabled"
