#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
NAMESPACE="nine"
SERVICE_NAME="nextcloud"
DOMAIN=$(config_get domain 'nine.local')
LDAP_PASS=$(config_get ldap_password 'ldapservice-password')
LDAP_BASE_DN=$(config_get ldap_base_dn 'DC=ldap,DC=nine,DC=local')
LDAP_HOST=$(config_get ldap_host "authentik.${DOMAIN}")

header "APPLY NEXTCLOUD"

# ─── DETECT DEPLOYMENT NAME ────────────────────────────────────────────────
DEPLOY_NAME=$(k8s_detect_deploy "$NAMESPACE" "$SERVICE_NAME")
if [ -z "$DEPLOY_NAME" ]; then
  ko "No deployment found for ${SERVICE_NAME}"
  exit 1
fi
info "detected deployment: ${DEPLOY_NAME}"

# ─── WAIT FOR POD ───────────────────────────────────────────────────────────
POD=$(k8s_ensure_pod "$NAMESPACE" "$SERVICE_NAME" 120)
if [ -z "$POD" ]; then
  ko "nextcloud: not running"
  exit 1
fi
ok "nextcloud: pod running"

# ─── WAIT FOR NEXTCLOUD TO BE READY ────────────────────────────────────────
info "waiting for Nextcloud to initialize..."
if k8s_wait_ready "$NAMESPACE" "$SERVICE_NAME" "Nextcloud init" 60 \
  -- bash -c "test -f /var/www/html/config/config.php && php occ status 2>/dev/null | grep -q 'installed: true'"; then
  ok "nextcloud: initialized"
else
  ko "nextcloud: initialization timeout"
  exit 1
fi

# ─── INSTALL PLUGINS ────────────────────────────────────────────────────────
section "Plugins"

for plugin in calendar user_ldap oidc_login; do
  if k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ app:list 2>/dev/null | grep -q "$plugin"; then
    dim "${plugin}: already installed"
  else
    info "installing ${plugin}..."
    k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ app:install "$plugin" 2>&1 | indent
    ok "${plugin}: installed"
  fi
done

# ─── CONFIGURE LDAP ─────────────────────────────────────────────────────────
section "LDAP Configuration"

LDAP_CONFIGURED=$(k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:show-config 2>/dev/null | grep -c "Server" || echo "0")
if [ "$LDAP_CONFIGURED" -gt 0 ]; then
  dim "LDAP: already configured"
else
  info "configuring LDAP connection..."
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:create-empty-config 2>&1 | indent

  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:set-config "s01" ldap_host "${LDAP_HOST}" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:set-config "s01" ldap_port 389 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:set-config "s01" ldap_base "${LDAP_BASE_DN}" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:set-config "s01" ldap_dn "cn=ldapservice,ou=users,${LDAP_BASE_DN}" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:set-config "s01" ldap_agent_password "${LDAP_PASS}" 2>&1 | indent

  LDAP_USERS_BASE="ou=users,${LDAP_BASE_DN}"
  LDAP_GROUPS_BASE="ou=groups,${LDAP_BASE_DN}"
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:set-config "s01" ldap_base_users "${LDAP_USERS_BASE}" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:set-config "s01" ldap_base_groups "${LDAP_GROUPS_BASE}" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:set-config "s01" ldap_user_filter_objectclass "inetOrgPerson" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:set-config "s01" ldap_group_filter_objectclass "groupOfNames" 2>&1 | indent

  if k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ ldap:test-config "s01" 2>&1 | grep -q "success"; then
    ok "LDAP: connection successful"
  else
    warn "LDAP: connection test failed (may need manual configuration)"
  fi
fi

# ─── CONFIGURE OIDC ─────────────────────────────────────────────────────────
section "OIDC Configuration"

OIDC_CONFIGURED=$(k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:get oidc_login 2>/dev/null | grep -c "provider-url" || echo "0")
if [ "$OIDC_CONFIGURED" -gt 0 ]; then
  dim "OIDC: already configured"
else
  info "configuring OIDC login..."
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login provider-url --value="https://authentik.${DOMAIN}/application/o/nextcloud/" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login client-id --value="nextcloud" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login client-secret --value="nextcloud-secret" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login redirect-url --value="https://cloud.${DOMAIN}/index.php/login/via oidc_login/" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login discovery-url --value="https://authentik.${DOMAIN}/application/o/nextcloud/.well-known/openid-configuration" 2>&1 | indent
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:app:set oidc_login auto-provision --value="1" 2>&1 | indent
  ok "OIDC: configured"
fi

# ─── CONFIGURE TRUSTED DOMAIN ───────────────────────────────────────────────
section "Trusted Domain"

TRUSTED_DOMAIN=$(k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:system:get trusted_domains 2>/dev/null | grep -c "cloud.${DOMAIN}" || echo "0")
if [ "$TRUSTED_DOMAIN" -gt 0 ]; then
  dim "trusted domain: already configured"
else
  info "adding trusted domain..."
  k8s_exec "$NAMESPACE" "$SERVICE_NAME" -- php occ config:system:set trusted_domains 1 --value="cloud.${DOMAIN}" 2>&1 | indent
  ok "trusted domain added"
fi

# ─── SUMMARY ────────────────────────────────────────────────────────────────
done_ok "nextcloud configured — access at https://cloud.${DOMAIN}"
