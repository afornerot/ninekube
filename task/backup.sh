#!/bin/bash
source "$(dirname "$0")/helpers.sh"

SERVICE="${1:-}"
BACKUP_PVC="${BACKUP_PVC:-}"
BACKUP_DB="${BACKUP_DB:-}"
BACKUP_BASE="${NINEKUBE_DIR}/backups"
PG_USER=$(config_get postgres_username 'authentik')
PG_PASS=$(config_get postgres_password 'changeme')

# Default: backup both if no flag specified
if [ -z "$BACKUP_PVC" ] && [ -z "$BACKUP_DB" ]; then
  BACKUP_PVC=true
  BACKUP_DB=true
fi

backup_pvc() {
  local pvc="$1" dest="$2"
  local pod_name="backup-pvc-$$-$(date +%s)"

  kubectl run "$pod_name" --restart=Never -n nine --image=busybox:latest \
    --overrides="{
      \"spec\": {
        \"volumes\": [
          {\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"${pvc}\"}},
          {\"name\": \"out\", \"emptyDir\": {}}
        ],
        \"containers\": [{
          \"name\": \"b\", \"image\": \"busybox:latest\",
          \"command\": [\"sh\",\"-c\",\"tar czf /out/${pvc}.tar.gz -C /data . && sleep infinity\"],
          \"volumeMounts\": [
            {\"name\": \"data\", \"mountPath\": \"/data\"},
            {\"name\": \"out\", \"mountPath\": \"/out\"}
          ]
        }],
        \"restartPolicy\": \"Never\"
      }
    }" 2>&1 | indent

  k8s_wait_pod "nine" "run=${pod_name}" 30
  kubectl cp "nine/${pod_name}:/out/${pvc}.tar.gz" "$dest" 2>&1 | indent
  kubectl delete pod "$pod_name" -n nine --ignore-not-found 2>/dev/null
}

backup_database() {
  local db_name="$1" dest="$2"
  local exists
  exists=$(kubectl exec -n nine dev-postgres-0 -- psql -U "$PG_USER" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${db_name}'" 2>/dev/null | tr -d '[:space:]')

  if [ "$exists" = "1" ]; then
    info "dumping database: ${db_name}..."
    kubectl exec -n nine dev-postgres-0 -- pg_dump -U "$PG_USER" "$db_name" | gzip > "$dest" 2>&1 | indent
    ok "database → ${dest}"
  else
    dim "no database '${db_name}'"
  fi
}

backup_service() {
  local svc="$1"
  local date_dir
  date_dir=$(date +%Y%m%d)
  local svc_dir="${BACKUP_BASE}/${svc}/${date_dir}"

  header "BACKUP: ${svc}"
  mkdir -p "${svc_dir}/pvc" "${svc_dir}/bdd"

  # PVC backup
  if [ "$BACKUP_PVC" = "true" ]; then
    local pvcs
    pvcs=$(kubectl get pvc -n nine -l "app.kubernetes.io/name=${svc}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | awk '$2=="Bound"{print $1}')
    if [ -n "$pvcs" ]; then
      for pvc in $pvcs; do
        info "backing up PVC: ${pvc}..."
        backup_pvc "$pvc" "${svc_dir}/pvc/${pvc}.tar.gz"
        ok "PVC → ${svc_dir}/pvc/${pvc}.tar.gz"
      done
    else
      dim "no PVCs"
    fi
  fi

  # Database backup
  if [ "$BACKUP_DB" = "true" ]; then
    backup_database "$svc" "${svc_dir}/bdd/${svc}.sql.gz"
  fi

  # Cleanup empty dirs
  rmdir "${svc_dir}/pvc" 2>/dev/null
  rmdir "${svc_dir}/bdd" 2>/dev/null

  local size
  size=$(du -sh "${svc_dir}" 2>/dev/null | cut -f1)
  done_ok "backup complete → ${svc_dir} (${size})"
}

# ─── MAIN ──────────────────────────────────────────────────────────────────────
if [ -n "$SERVICE" ]; then
  backup_service "$SERVICE"
else
  section "Backing up all active services"
  found=false
  for service_dir in "${NINEKUBE_DIR}/services"/*/; do
    [ ! -d "$service_dir" ] && continue
    local_svc=$(basename "$service_dir")
    if kubectl get deployment -n nine -l "app.kubernetes.io/name=${local_svc}" --no-headers 2>/dev/null | grep -q .; then
      backup_service "$local_svc"
      found=true
    fi
  done
  if [ "$found" = false ]; then
    warn "no active services to backup"
  fi
fi
