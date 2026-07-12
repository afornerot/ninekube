#!/bin/bash
source "$(dirname "$0")/helpers.sh"

PG_PASS=$(config_get pg_password 'changeme')
POSTGRES_USER=$(config_get postgres_username 'postgres')

header "PREDEPLOY POSTGRES"

# ─── POSTGRES SECRET ────────────────────────────────────────────────────────────
info "creating postgres secret..."
apply_manifest <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: nine
type: Opaque
stringData:
  username: "${POSTGRES_USER}"
  password: "${PG_PASS}"
EOF
ok "postgres secret: created"

done_ok "postgres predeploy"
