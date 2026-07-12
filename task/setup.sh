#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"

header "SETUP"

# ─── INSTALL ────────────────────────────────────────────────────────────────────
bash "$(dirname "$0")/install.sh"

# ─── CERT-MANAGER ───────────────────────────────────────────────────────────────
bash "$(dirname "$0")/cert-manager-install.sh"

# ─── CONFIGURE ──────────────────────────────────────────────────────────────────
bash "$(dirname "$0")/config-set.sh"

# ─── PREDEPLOY SHARED (namespace + shared configmap/secrets) ─────────────────────
bash "$(dirname "$0")/predeploy-shared.sh" "$ENV"

# ─── PREDEPLOY CORE SERVICES (secrets/configmaps needed before kustomize apply) ─
bash "$(dirname "$0")/predeploy-postgres.sh" "$ENV"
bash "$(dirname "$0")/predeploy-ninegate.sh" "$ENV"
bash "$(dirname "$0")/predeploy-dex.sh" "$ENV"
bash "$(dirname "$0")/predeploy-minio.sh" "$ENV"

# ─── PREDEPLOY ENABLED SERVICES ─────────────────────────────────────────────────
for service_dir in "${NINEKUBE_DIR}/services"/*/; do
  [ ! -d "$service_dir" ] && continue
  service=$(basename "$service_dir")
  if [ -L "${BASE_DIR}/${service}" ]; then
    if [ -x "task/predeploy-${service}.sh" ]; then
      bash "$(dirname "$0")/predeploy-${service}.sh" "$ENV"
    fi
  fi
done

# ─── TRAEFIK HTTP→HTTPS REDIRECT ───────────────────────────────────────────────
bash "$(dirname "$0")/predeploy-traefik.sh"

# ─── PREDEPLOY CERT (ClusterIssuer + Middleware) ────────────────────────────────
bash "$(dirname "$0")/predeploy-cert.sh" "$ENV"

# ─── DEPLOY ─────────────────────────────────────────────────────────────────────
bash "$(dirname "$0")/deploy.sh" "$ENV"

# ─── POSTDEPLOY CERT (Ingress patching) ────────────────────────────────────────
bash "$(dirname "$0")/postdeploy-cert.sh" "$ENV"

# ─── POSTDEPLOY MINIO ───────────────────────────────────────────────────────────
bash "$(dirname "$0")/postdeploy-minio.sh" "$ENV"

# ─── POSTDEPLOY NINEGATE ───────────────────────────────────────────────────────
bash "$(dirname "$0")/postdeploy-ninegate.sh" "$ENV"

# ─── POSTDEPLOY DEX ────────────────────────────────────────────────────────────
bash "$(dirname "$0")/postdeploy-dex.sh" "$ENV"

# ─── POSTDEPLOY ENABLED SERVICES ────────────────────────────────────────────────
section "Active Services"
for service_dir in "${NINEKUBE_DIR}/services"/*/; do
  [ ! -d "$service_dir" ] && continue
  service=$(basename "$service_dir")
  if [ -L "${BASE_DIR}/${service}" ]; then
    if [ -x "task/postdeploy-${service}.sh" ]; then
      bash "$(dirname "$0")/postdeploy-${service}.sh" "$ENV"
    else
      dim "${service}: no postdeploy script"
    fi
  fi
done

# ─── SUMMARY ────────────────────────────────────────────────────────────────────
header "SUMMARY"
section "Access"
DOMAIN=$(config_get domain 'nine.local')
ADMIN_USER=$(config_get admin_username 'admin')
hint "Add to /etc/hosts:"
hint "  $(hostname -I | awk '{print $1}') ninegate.${DOMAIN} dex.${DOMAIN} minio.${DOMAIN} glauth.${DOMAIN}"
hint ""
hint "Glauth LDAPS: ldaps://glauth.${DOMAIN}:30636"
section "Credentials"
hint "Admin: ${ADMIN_USER} / see ${CONFIG_FILE}"
done_ok "setup complete"
