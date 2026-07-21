#!/bin/bash
source "$(dirname "$0")/helpers.sh"

CLIENT="${1:-}"
BACKUP_BASE="${NINEKUBE_DIR}/backups"

backup_pvc() {
  local ns="$1" pvc="$2" dest="$3"
  local pod_name="backup-pvc-$$-$(date +%s)"

  kubectl run "$pod_name" --restart=Never -n "$ns" --image=busybox:latest \
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

  k8s_wait_pod "$ns" "run=${pod_name}" 30
  kubectl cp "${ns}/${pod_name}:/out/${pvc}.tar.gz" "$dest" 2>&1 | indent
  kubectl delete pod "$pod_name" -n "$ns" --ignore-not-found 2>/dev/null
}

backup_database() {
  local ns="$1" db_name="$2" dest="$3"
  local pg_pod
  pg_pod=$(kubectl get pod -n "$ns" -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$pg_pod" ] && return 1

  local exists
  exists=$(kubectl exec -n "$ns" "$pg_pod" -- psql -U ninekube -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${db_name}'" 2>/dev/null | tr -d '[:space:]')

  if [ "$exists" = "1" ]; then
    info "dumping database: ${db_name}..."
    kubectl exec -n "$ns" "$pg_pod" -- pg_dump -U ninekube "$db_name" | gzip > "$dest" 2>&1 | indent
    ok "database → ${dest}"
  else
    dim "no database '${db_name}'"
  fi
}

backup_client() {
  local cn="$1"
  local ns
  ns=$(cn_namespace "$cn")
  [ -z "$ns" ] && { warn "ClientNamespace '$cn' not provisioned"; return 1; }

  local date_dir
  date_dir=$(date +%Y%m%d)
  local client_dir="${BACKUP_BASE}/${cn}/${date_dir}"

  header "BACKUP: ${cn} (namespace: ${ns})"
  mkdir -p "${client_dir}/pvc" "${client_dir}/bdd"

  # Backup PVCs
  local pvcs
  pvcs=$(kubectl get pvc -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | awk '$2=="Bound"{print $1}')
  if [ -n "$pvcs" ]; then
    for pvc in $pvcs; do
      info "backing up PVC: ${pvc}..."
      backup_pvc "$ns" "$pvc" "${client_dir}/pvc/${pvc}.tar.gz"
      ok "PVC → ${client_dir}/pvc/${pvc}.tar.gz"
    done
  else
    dim "no PVCs"
  fi

  # Backup PostgreSQL
  info "backing up PostgreSQL..."
  backup_database "$ns" "ninekube" "${client_dir}/bdd/ninekube.sql.gz"

  # Cleanup empty dirs
  rmdir "${client_dir}/pvc" 2>/dev/null
  rmdir "${client_dir}/bdd" 2>/dev/null

  local size
  size=$(du -sh "${client_dir}" 2>/dev/null | cut -f1)
  done_ok "backup complete → ${client_dir} (${size})"
}

# ─── MAIN ──────────────────────────────────────────────────────────────────────
if [ -n "$CLIENT" ]; then
  backup_client "$CLIENT"
else
  section "Backing up all client namespaces"
  found=false
  for cn in $(cn_list 2>/dev/null); do
    backup_client "$cn"
    found=true
  done
  if [ "$found" = false ]; then
    warn "no client namespaces to backup"
  fi
fi
