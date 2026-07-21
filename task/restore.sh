#!/bin/bash
source "$(dirname "$0")/helpers.sh"

CLIENT="${1:-}"
BACKUP_BASE="${NINEKUBE_DIR}/backups"

restore_pvc() {
  local ns="$1" pvc="$2" src="$3"
  local pod_name="restore-pvc-$$-$(date +%s)"

  kubectl run "$pod_name" --restart=Never -n "$ns" --image=busybox:latest \
    --overrides="{
      \"spec\": {
        \"volumes\": [
          {\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"${pvc}\"}},
          {\"name\": \"in\", \"emptyDir\": {}}
        ],
        \"containers\": [{
          \"name\": \"b\", \"image\": \"busybox:latest\",
          \"command\": [\"sh\",\"-c\",\"tar xzf /in/${pvc}.tar.gz -C /data && sleep infinity\"],
          \"volumeMounts\": [
            {\"name\": \"data\", \"mountPath\": \"/data\"},
            {\"name\": \"in\", \"mountPath\": \"/in\"}
          ]
        }],
        \"restartPolicy\": \"Never\"
      }
    }" 2>&1 | indent

  kubectl cp "$src" "${ns}/${pod_name}:/in/${pvc}.tar.gz" 2>&1 | indent
  k8s_wait_pod "$ns" "run=${pod_name}" 30
  kubectl delete pod "$pod_name" -n "$ns" --ignore-not-found 2>/dev/null
}

restore_database() {
  local ns="$1" db_name="$2" src="$3"
  local pg_pod
  pg_pod=$(kubectl get pod -n "$ns" -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$pg_pod" ] && { warn "PostgreSQL pod not found"; return 1; }

  info "restoring database: ${db_name}..."
  gunzip -c "$src" | kubectl exec -i -n "$ns" "$pg_pod" -- psql -U ninekube "$db_name" 2>&1 | indent
  ok "database restored"
}

restore_client() {
  local cn="$1"
  local ns
  ns=$(cn_namespace "$cn")
  [ -z "$ns" ] && { warn "ClientNamespace '$cn' not provisioned"; return 1; }

  local client_dir="${BACKUP_BASE}/${cn}"
  [ ! -d "$client_dir" ] && { warn "no backups found for '$cn'"; return 1; }

  # Select backup date
  echo "Available backups for ${cn}:"
  select date_dir in $(ls -1 "$client_dir" | sort -r); do
    [ -n "$date_dir" ] && break
    echo "Invalid selection"
  done

  local restore_dir="${client_dir}/${date_dir}"
  header "RESTORE: ${cn} from ${date_dir}"

  # Restore PVCs
  if [ -d "${restore_dir}/pvc" ]; then
    for tar_file in "${restore_dir}/pvc"/*.tar.gz; do
      [ ! -f "$tar_file" ] && continue
      local pvc_name
      pvc_name=$(basename "$tar_file" .tar.gz)
      info "restoring PVC: ${pvc_name}..."
      restore_pvc "$ns" "$pvc_name" "$tar_file"
      ok "PVC ${pvc_name} restored"
    done
  fi

  # Restore databases
  if [ -d "${restore_dir}/bdd" ]; then
    for sql_file in "${restore_dir}/bdd"/*.sql.gz; do
      [ ! -f "$sql_file" ] && continue
      local db_name
      db_name=$(basename "$sql_file" .sql.gz)
      restore_database "$ns" "$db_name" "$sql_file"
    done
  fi

  done_ok "restore complete for ${cn}"
}

# ─── MAIN ──────────────────────────────────────────────────────────────────────
if [ -n "$CLIENT" ]; then
  restore_client "$CLIENT"
else
  section "Select client to restore"
  clients=($(cn_list 2>/dev/null))
  if [ ${#clients[@]} -eq 0 ]; then
    warn "no client namespaces found"
    exit 1
  fi
  echo "Available clients:"
  select cn in "${clients[@]}"; do
    [ -n "$cn" ] && break
    echo "Invalid selection"
  done
  restore_client "$cn"
fi
