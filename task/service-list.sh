#!/bin/bash
source "$(dirname "$0")/helpers.sh"

SERVICES_DIR="${NINEKUBE_DIR}/services"
BASE_DIR="${NINEKUBE_DIR}/base"

header "AVAILABLE SERVICES"

for service_dir in "${SERVICES_DIR}"/*/; do
  [ ! -d "$service_dir" ] && continue
  service=$(basename "$service_dir")
  if [ -L "${BASE_DIR}/${service}" ]; then
    ok "${service} (enabled)"
  else
    dim "${service}"
  fi
done

echo ""
hint "Enable:  task service-enable SERVICE=<name>"
hint "Disable: task service-disable SERVICE=<name>"
