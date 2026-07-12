#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
PREFIX="${ENV}"

header "POSTDEPLOY AUTHENTIK"

# ─── CLEAN START: avoid worker idle-in-transaction blocking server migrations ──
info "scaling down authentik deployments..."
kubectl scale deployment "${PREFIX}-authentik-server" "${PREFIX}-authentik-worker" -n nine --replicas=0 2>&1 | indent
sleep 2

info "killing stale database connections..."
if kubectl get pod "${PREFIX}-postgres-0" -n nine &>/dev/null; then
  kubectl exec -n nine "${PREFIX}-postgres-0" -- psql -U authentik -d authentik -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='authentik' AND pid != pg_backend_pid();" 2>&1 | indent
else
  dim "postgres not running, skipping"
fi
ok "clean state ready"

# ─── START SERVER ONLY (migrations + blueprint apply) ──────────────────────────
info "starting authentik-server (migrations + blueprint)..."
kubectl scale deployment "${PREFIX}-authentik-server" -n nine --replicas=1 2>&1 | indent

if ! k8s_wait_pod "nine" "app.kubernetes.io/component=server" 120; then
  ko "authentik: server not running"
  exit 1
fi
ok "authentik: pod running"

POD=$(k8s_pod "nine" "app.kubernetes.io/component=server")

# ─── WAIT FOR HEALTH (migrations + blueprint can take up to 10 min) ───────────
info "waiting for authentik API (migrations + blueprint can take up to 10 min)..."
for i in $(seq 1 120); do
  HTTP_CODE=$(kubectl exec -n nine "$POD" -c authentik-server -- \
    curl -s -o /dev/null -w "%{http_code}" http://localhost:9000/-/health/ready/ 2>/dev/null || echo "000")
  [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ] && break
  [ "$((i % 12))" -eq 0 ] && dim "still waiting... (attempt ${i}/120, last: ${HTTP_CODE})"
  [ "$i" = "120" ] && ko "authentik: API not responding after 10 min" && exit 1
  sleep 5
done
ok "authentik: API ready"

# ─── START WORKER (after migrations + blueprint are done) ──────────────────────
info "starting authentik-worker..."
kubectl scale deployment "${PREFIX}-authentik-worker" -n nine --replicas=1 2>&1 | indent
ok "authentik-worker started"

# ─── CHECK BLUEPRINT STATUS ────────────────────────────────────────────────────
info "checking blueprint application..."
sleep 5
BLUEPRINT_STATUS=$(kubectl exec -n nine "$POD" -c authentik-server -- \
  python -c "
import django, os
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'authentik.settings')
django.setup()
from authentik.blueprints.models import BlueprintInstance
for bi in BlueprintInstance.objects.all():
    print(f'{bi.name}:{bi.status}')
if not BlueprintInstance.objects.exists():
    print('no-instances')
" 2>&1 || echo "error")

echo "$BLUEPRINT_STATUS" | while IFS= read -r line; do
  dim "blueprint: ${line}"
done

done_ok "authentik configured (via blueprint)"
