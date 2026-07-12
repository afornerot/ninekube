#!/bin/bash
source "$(dirname "$0")/helpers.sh"

if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

header "UNINSTALL"

PG_USER=$(config_get postgres_username 'postgres')

# ─── LIST CORE COMPONENTS ─────────────────────────────────────────────────────
section "Core components that will be deleted:"

# RustFS
rustfs_pvcs=$(kubectl get pvc -n nine -l "app.kubernetes.io/name=rustfs" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
bold "  rustfs"
[ -n "$rustfs_pvcs" ] && dim "    PVCs: ${rustfs_pvcs}"

# ─── LIST SERVICES ────────────────────────────────────────────────────────────
section "Active services that will be deleted:"
for service_dir in "${NINEKUBE_DIR}/services"/*/; do
  [ ! -d "$service_dir" ] && continue
  svc=$(basename "$service_dir")
  if ! kubectl get deployment -n nine -l "app.kubernetes.io/name=${svc}" --no-headers 2>/dev/null | grep -q .; then
    continue
  fi
  echo ""
  bold "  ${svc}"

  pvcs=$(kubectl get pvc -n nine -l "app.kubernetes.io/name=${svc}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  [ -n "$pvcs" ] && dim "    PVCs: ${pvcs}"

  db_exists=$(kubectl exec -n nine dev-postgres-0 -- psql -U "$PG_USER" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${svc}'" 2>/dev/null | tr -d '[:space:]')
  [ "$db_exists" = "1" ] && dim "    Database: ${svc}"
done

echo ""

# ─── CONFIRMATION ─────────────────────────────────────────────────────────────
if ! ask_yn "Uninstall k3s and delete all cluster data?"; then
  ko "aborted"
  exit 0
fi

# ─── BACKUP PVCs (rustfs + services) ──────────────────────────────────────────
echo ""
if ask_yn "Backup PVC data before uninstalling?"; then
  # RustFS
  if [ -n "$rustfs_pvcs" ]; then
    BACKUP_PVC=true BACKUP_DB=false bash "$(dirname "$0")/backup.sh" "rustfs"
  fi
  # Services
  for service_dir in "${NINEKUBE_DIR}/services"/*/; do
    [ ! -d "$service_dir" ] && continue
    svc=$(basename "$service_dir")
    pvcs=$(kubectl get pvc -n nine -l "app.kubernetes.io/name=${svc}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -n "$pvcs" ]; then
      BACKUP_PVC=true BACKUP_DB=false bash "$(dirname "$0")/backup.sh" "$svc"
    fi
  done
fi

# ─── BACKUP DATABASES ─────────────────────────────────────────────────────────
echo ""
if ask_yn "Backup databases before uninstalling?"; then
  # Services
  for service_dir in "${NINEKUBE_DIR}/services"/*/; do
    [ ! -d "$service_dir" ] && continue
    svc=$(basename "$service_dir")
    db_exists=$(kubectl exec -n nine dev-postgres-0 -- psql -U "$PG_USER" -tAc \
      "SELECT 1 FROM pg_database WHERE datname='${svc}'" 2>/dev/null | tr -d '[:space:]')
    if [ "$db_exists" = "1" ]; then
      BACKUP_PVC=false BACKUP_DB=true bash "$(dirname "$0")/backup.sh" "$svc"
    fi
  done
fi

# ─── UNINSTALL ────────────────────────────────────────────────────────────────
info "k3s: uninstalling..."
/usr/local/bin/k3s-uninstall.sh > /dev/null 2>&1
ok "k3s: uninstalled"
done_ok "cluster uninstalled"
