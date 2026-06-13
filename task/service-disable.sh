#!/bin/bash
source "$(dirname "$0")/helpers.sh"

SERVICE="${1:?Usage: service-disable SERVICE=<service>}"
SERVICES_DIR="${NINEKUBE_DIR}/services"
BASE_DIR="${NINEKUBE_DIR}/base"
KUSTOMIZE_FILE="${BASE_DIR}/kustomization.yaml"
PG_USER=$(config_get postgres_username 'authentik')
PG_PASS=$(config_get postgres_password 'changeme')

header "DISABLE SERVICE: ${SERVICE}"

# Detect database
DB_EXISTS=$(kubectl exec -n nine dev-postgres-0 -- psql -U "$PG_USER" -tAc \
  "SELECT 1 FROM pg_database WHERE datname='${SERVICE}'" 2>/dev/null | tr -d '[:space:]')

# List what will be deleted
info "resources that will be deleted:"
kubectl get deployment,service,ingress,configmap -n nine -l "app.kubernetes.io/name=${SERVICE}" --no-headers 2>/dev/null | sed 's/^/    /'
PVCS=$(kubectl get pvc -n nine -l "app.kubernetes.io/name=${SERVICE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
if [ -n "$PVCS" ]; then
  echo ""
  warn "PVCs (data will be lost if deleted):"
  kubectl get pvc -n nine -l "app.kubernetes.io/name=${SERVICE}" --no-headers 2>/dev/null | sed 's/^/    /'
fi
if [ "$DB_EXISTS" = "1" ]; then
  echo ""
  warn "Database: ${SERVICE} (data will be lost if deleted)"
fi
echo ""

# Confirmation
if ! ask_yn "Delete '${SERVICE}' and all its resources?"; then
  ko "aborted"
  exit 0
fi

# Delete k8s resources (except PVC)
info "deleting k8s resources..."
kubectl delete deployment -n nine -l "app.kubernetes.io/name=${SERVICE}" --ignore-not-found 2>&1 | indent
kubectl delete service -n nine -l "app.kubernetes.io/name=${SERVICE}" --ignore-not-found 2>&1 | indent
kubectl delete ingress -n nine -l "app.kubernetes.io/name=${SERVICE}" --ignore-not-found 2>&1 | indent
kubectl delete configmap -n nine -l "app.kubernetes.io/name=${SERVICE}" --ignore-not-found 2>&1 | indent

# Ask about PVCs
if [ -n "$PVCS" ]; then
  echo ""
  if ask_yn "Also delete PVCs (data will be permanently lost)?"; then
    echo ""
    if ask_yn "Backup PVC data before deleting?"; then
      BACKUP_PVC=true BACKUP_DB=false bash "$(dirname "$0")/backup.sh" "$SERVICE"
    fi
    info "deleting PVCs..."
    for pvc in $PVCS; do
      kubectl delete pvc "$pvc" -n nine 2>&1 | indent
    done
    ok "PVCs deleted"
  else
    dim "PVCs preserved — delete manually with: kubectl delete pvc <name> -n nine"
  fi
fi

# Ask about database
if [ "$DB_EXISTS" = "1" ]; then
  echo ""
  if ask_yn "Also delete database '${SERVICE}' (data will be permanently lost)?"; then
    echo ""
    if ask_yn "Backup database before deleting?"; then
      BACKUP_PVC=false BACKUP_DB=true bash "$(dirname "$0")/backup.sh" "$SERVICE"
    fi
    info "dropping database ${SERVICE}..."
    kubectl exec -n nine dev-postgres-0 -- psql -U "$PG_USER" -c "DROP DATABASE IF EXISTS ${SERVICE}" 2>&1 | indent
    ok "database ${SERVICE} dropped"
  else
    dim "database preserved — drop manually with: kubectl exec -n nine dev-postgres-0 -- psql -U ${PG_USER} -c 'DROP DATABASE ${SERVICE}'"
  fi
fi

# Remove symlink from base/
if [ -L "${BASE_DIR}/${SERVICE}" ]; then
  info "Removing symlink: base/${SERVICE}"
  rm "${BASE_DIR}/${SERVICE}"
  ok "Symlink removed"
else
  warn "No symlink found for '${SERVICE}' in base/"
fi

# Remove from kustomization.yaml
if grep -q "^  - ${SERVICE}$" "$KUSTOMIZE_FILE" 2>/dev/null; then
  info "Removing '${SERVICE}' from base/kustomization.yaml"
  sed -i "/^  - ${SERVICE}$/d" "$KUSTOMIZE_FILE"
  ok "Removed from kustomization.yaml"
else
  warn "Service '${SERVICE}' not found in kustomization.yaml"
fi

done_ok "Service '${SERVICE}' disabled"
