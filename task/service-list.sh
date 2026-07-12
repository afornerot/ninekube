#!/bin/bash
source "$(dirname "$0")/helpers.sh"

SERVICES_DIR="${NINEKUBE_DIR}/services"
ENABLED_DIR="${BASE_DIR}/enabled-services"

header "AVAILABLE SERVICES"

for service_dir in "${SERVICES_DIR}"/*/; do
  [ ! -d "$service_dir" ] && continue
  service=$(basename "$service_dir")
  if [ -L "${ENABLED_DIR}/${service}" ]; then
    ok "${service} (enabled)"
  else
    dim "${service}"
  fi
done

echo ""
hint "Enable:  task service-enable SERVICE=<name>"
hint "Disable: task service-disable SERVICE=<name>"
