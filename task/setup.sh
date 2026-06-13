#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"

header "SETUP"

# ─── INSTALL ────────────────────────────────────────────────────────────────────
bash "$(dirname "$0")/install.sh"

# ─── CERT-MANAGER ───────────────────────────────────────────────────────────────
bash "$(dirname "$0")/cert-manager-install.sh"

# ─── CONFIGURE ──────────────────────────────────────────────────────────────────
bash "$(dirname "$0")/apply-config.sh"

# ─── APPLY SECRETS ──────────────────────────────────────────────────────────────
bash "$(dirname "$0")/apply-secrets.sh" "$ENV"

# ─── DEPLOY ─────────────────────────────────────────────────────────────────────
bash "$(dirname "$0")/deploy.sh" "$ENV"

# ─── TRAEFIK HTTP→HTTPS REDIRECT ───────────────────────────────────────────────
bash "$(dirname "$0")/apply-traefik-redirect.sh"

# ─── APPLY CERT ─────────────────────────────────────────────────────────────────
bash "$(dirname "$0")/apply-cert.sh" "$ENV"

# ─── APPLY MINIO ───────────────────────────────────────────────────────────────
bash "$(dirname "$0")/apply-minio.sh" "$ENV"

# ─── APPLY AUTHENTIK ────────────────────────────────────────────────────────────
bash "$(dirname "$0")/apply-authentik.sh"

# ─── APPLY SERVICES ─────────────────────────────────────────────────────────────
section "Active Services"
for service_dir in "${NINEKUBE_DIR}/services"/*/; do
  [ ! -d "$service_dir" ] && continue
  service=$(basename "$service_dir")
  if [ -L "${BASE_DIR}/${service}" ]; then
    if [ -x "task/apply-${service}.sh" ]; then
      bash "$(dirname "$0")/apply-${service}.sh" "$ENV"
    else
      dim "${service}: no apply script"
    fi
  fi
done

# ─── SUMMARY ────────────────────────────────────────────────────────────────────
header "SUMMARY"
section "Access"
DOMAIN=$(config_get domain 'nine.local')
ADMIN_USER=$(config_get admin_username 'admin')
hint "Add to /etc/hosts:"
hint "  $(hostname -I | awk '{print $1}') authentik.${DOMAIN} minio.${DOMAIN}"
section "Credentials"
hint "Admin: ${ADMIN_USER} / see ${CONFIG_FILE}"
hint "LDAP: ldapservice / see ${CONFIG_FILE}"
done_ok "setup complete"
