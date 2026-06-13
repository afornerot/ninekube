#!/bin/bash
source "$(dirname "$0")/helpers.sh"

SERVICE="${1:-}"
BACKUP_BASE="${NINEKUBE_DIR}/backups"
PG_USER=$(config_get postgres_username 'authentik')

restore_service() {
  local svc="$1"

  # Check if backup exists
  if [ ! -d "${BACKUP_BASE}/${svc}" ]; then
    dim "${svc}: no backup found"
    return
  fi

  # List available backups
  local backups
  backups=$(ls -1d "${BACKUP_BASE}/${svc}"/*/ 2>/dev/null | sort -r)
  local count
  count=$(echo "$backups" | wc -l)

  if [ -z "$backups" ]; then
    dim "${svc}: no backup found"
    return
  fi

  header "RESTORE: ${svc}"

  # Select backup date
  local backup_dir
  if [ "$count" -gt 1 ]; then
    section "Available backups:"
    local i=1
    while IFS= read -r dir; do
      local date
      date=$(basename "$dir")
      local pvc_count=0
      local bdd_count=0
      [ -d "${dir}/pvc" ] && pvc_count=$(find "${dir}/pvc" -name "*.tar.gz" | wc -l)
      [ -d "${dir}/bdd" ] && bdd_count=$(find "${dir}/bdd" -name "*.sql.gz" | wc -l)
      dim "  ${i}) ${date} (PVC: ${pvc_count}, BDD: ${bdd_count})"
      i=$((i + 1))
    done <<< "$backups"
    echo ""

    local choice
    echo -e -n "  ${BOLD}${CYAN}?${NC} Select backup to restore [1-${count}] ${BOLD}[1]${NC} "
    read -r choice
    [ -z "$choice" ] && choice=1
    backup_dir=$(echo "$backups" | sed -n "${choice}p")
  else
    backup_dir=$(echo "$backups" | head -1)
    local date
    date=$(basename "$backup_dir")
    dim "Using backup: ${date}"
  fi

  if [ ! -d "$backup_dir" ]; then
    ko "invalid backup selection"
    return
  fi

  # Restore PVC
  local pvc_files
  pvc_files=$(find "${backup_dir}/pvc" -name "*.tar.gz" 2>/dev/null)
  if [ -n "$pvc_files" ]; then
    echo ""
    if ask_yn "Restore PVC data for '${svc}'?"; then
      for pvc_file in $pvc_files; do
        local pvc_name
        pvc_name=$(basename "$pvc_file" .tar.gz)
        info "restoring PVC: ${pvc_name}..."

        # Find or create PVC
        local existing_pvc
        existing_pvc=$(kubectl get pvc -n nine -l "app.kubernetes.io/name=${svc}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -z "$existing_pvc" ]; then
          # Create PVC with same size as backup (default 5Gi)
          kubectl apply -f - <<EOF 2>&1 | indent
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: nine
  labels:
    app.kubernetes.io/name: ${svc}
    app.kubernetes.io/part-of: ninekube
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: local-path
EOF
        fi

        # Create restore pod
        local pod_name="restore-pvc-$$-$(date +%s)"
        kubectl run "$pod_name" --restart=Never -n nine --image=busybox:latest \
          --overrides="{
            \"spec\": {
              \"volumes\": [
                {\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"${pvc_name}\"}},
                {\"name\": \"backup\", \"emptyDir\": {}}
              ],
              \"containers\": [{
                \"name\": \"b\", \"image\": \"busybox:latest\",
                \"command\": [\"sleep\", \"infinity\"],
                \"volumeMounts\": [
                  {\"name\": \"data\", \"mountPath\": \"/data\"},
                  {\"name\": \"backup\", \"mountPath\": \"/backup\"}
                ]
              }],
              \"restartPolicy\": \"Never\"
            }
          }" 2>&1 | indent

        k8s_wait_pod "nine" "run=${pod_name}" 30
        kubectl cp "$pvc_file" "nine/${pod_name}:/backup/$(basename $pvc_file)" 2>&1 | indent
        kubectl exec -n nine "$pod_name" -- sh -c "tar xzf /backup/$(basename $pvc_file) -C /data" 2>&1 | indent
        kubectl delete pod "$pod_name" -n nine --ignore-not-found 2>/dev/null
        ok "PVC ${pvc_name} restored"
      done
    fi
  fi

  # Restore database
  local bdd_files
  bdd_files=$(find "${backup_dir}/bdd" -name "*.sql.gz" 2>/dev/null)
  if [ -n "$bdd_files" ]; then
    echo ""
    if ask_yn "Restore database for '${svc}'?"; then
      for bdd_file in $bdd_files; do
        local db_name
        db_name=$(basename "$bdd_file" .sql.gz)
        info "restoring database: ${db_name}..."

        # Create database if it doesn't exist
        kubectl exec -n nine dev-postgres-0 -- psql -U "$PG_USER" -tAc \
          "SELECT 1 FROM pg_database WHERE datname='${db_name}'" 2>/dev/null | tr -d '[:space:]'
        local db_exists
        db_exists=$(kubectl exec -n nine dev-postgres-0 -- psql -U "$PG_USER" -tAc \
          "SELECT 1 FROM pg_database WHERE datname='${db_name}'" 2>/dev/null | tr -d '[:space:]')

        if [ "$db_exists" != "1" ]; then
          kubectl exec -n nine dev-postgres-0 -- psql -U "$PG_USER" -c "CREATE DATABASE ${db_name}" 2>&1 | indent
        fi

        # Drop and recreate tables
        kubectl exec -n nine dev-postgres-0 -- psql -U "$PG_USER" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public" 2>&1 | indent

        # Restore from dump
        cat "$bdd_file" | kubectl exec -i -n nine dev-postgres-0 -- psql -U "$PG_USER" -d "$db_name" 2>&1 | indent
        ok "database ${db_name} restored"
      done
    fi
  fi
}

# ─── MAIN ──────────────────────────────────────────────────────────────────────
if [ -n "$SERVICE" ]; then
  restore_service "$SERVICE"
else
  section "Checking backups..."
  found=false

  # Core components
  for component in minio authentik; do
    if [ -d "${BACKUP_BASE}/${component}" ]; then
      restore_service "$component"
      found=true
    fi
  done

  # Services
  for service_dir in "${NINEKUBE_DIR}/services"/*/; do
    [ ! -d "$service_dir" ] && continue
    svc=$(basename "$service_dir")
    if [ -d "${BACKUP_BASE}/${svc}" ]; then
      restore_service "$svc"
      found=true
    fi
  done

  if [ "$found" = false ]; then
    warn "no backups found"
  fi
fi
