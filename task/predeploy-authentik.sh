#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
PREFIX="${ENV}"

DOMAIN=$(config_get domain 'nine.local')
AUTHENTIK_SECRET_KEY=$(config_get authentik_secret_key '')
if [ -z "$AUTHENTIK_SECRET_KEY" ]; then
  AUTHENTIK_SECRET_KEY=$(head -c 64 /dev/urandom | base64 | tr -d '=/+' | head -c 64)
  config_set authentik_secret_key "$AUTHENTIK_SECRET_KEY"
fi
ADMIN_USER=$(config_get admin_username 'admin')
ADMIN_EMAIL=$(config_get admin_email "admin@${DOMAIN}")
ADMIN_PASS=$(config_get admin_password 'changeme')
LDAP_PASS=$(config_get ldap_password 'ldapservice-password')
LDAP_BASE_DN=$(config_get ldap_base_dn 'DC=ldap,DC=nine,DC=local')
PG_PASS=$(config_get pg_password 'changeme')

header "PREDEPLOY AUTHENTIK"

# ─── AUTHENTIK SECRET (dynamic values — created before deploy) ──────────────────
info "creating authentik secret..."
AUTHENTIK_URL="https://authentik.${DOMAIN}"
apply_manifest <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: authentik-secret
  namespace: nine
type: Opaque
stringData:
  AUTHENTIK_SECRET_KEY: "${AUTHENTIK_SECRET_KEY}"
  AUTHENTIK_POSTGRESQL__PASSWORD: "${PG_PASS}"
  AUTHENTIK_BOOTSTRAP_USERNAME: "${ADMIN_USER}"
  AUTHENTIK_BOOTSTRAP_PASSWORD: "${ADMIN_PASS}"
  AUTHENTIK_BOOTSTRAP_EMAIL: "${ADMIN_EMAIL}"
  AUTHENTIK_HOST: "${AUTHENTIK_URL}"
  AUTHENTIK_HOST_BROWSER: "${AUTHENTIK_URL}"
EOF
ok "authentik secret: created"

# ─── AUTHENTIK BLUEPRINT ────────────────────────────────────────────────────────
info "applying authentik blueprint..."
BLUEPRINT_NAME="ninekube-authentik-blueprint"
LDAP_DN="cn=ldapservice,ou=users,${LDAP_BASE_DN}"

apply_manifest <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${BLUEPRINT_NAME}
  namespace: nine
  labels:
    app.ninekube/blueprint: "true"
data:
  ninekube-setup.yaml: |
    version: 1
    metadata:
      name: "Ninekube - LDAP + Proxy + Users"
      labels:
        blueprints.goauthentik.io/instantiate: "true"

    entries:
      # ─── LDAP PROVIDER ──────────────────────────────────────────────────
      - model: authentik_providers_ldap.ldapprovider
        id: ldap-provider
        identifiers:
          name: ldap
        attrs:
          base_dn: "${LDAP_BASE_DN}"
          certificate: !Find [authentik_crypto.certificatekeypair, [name, "authentik Self-signed Certificate"]]
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-invalidation-flow]]
          bind_mode: direct
          search_mode: cached

      # ─── LDAP APPLICATION ───────────────────────────────────────────────
      - model: authentik_core.application
        id: ldap-app
        identifiers:
          slug: ldap
        attrs:
          name: LDAP
          meta_icon: "/application-icons/generic.svg"
          meta_description: "LDAP Provider for Ninekube"
          open_in_new_tab: false
          provider: !KeyOf ldap-provider

      # ─── LDAP OUTPOST ───────────────────────────────────────────────────
      - model: authentik_outposts.outpost
        id: ldap-outpost
        identifiers:
          name: LDAP Outpost
        attrs:
          type: ldap
          providers:
            - !KeyOf ldap-provider

      # ─── PROXY PROVIDER (Forward Auth) ──────────────────────────────────
      - model: authentik_proxies.proxyprovider
        id: proxy-provider
        identifiers:
          name: cluster-proxy
        attrs:
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-invalidation-flow]]
          external_host: "https://authentik.${DOMAIN}"
          mode: forward_domain
          cookie_domain: ".${DOMAIN}"

      # ─── PROXY APPLICATION ──────────────────────────────────────────────
      - model: authentik_core.application
        id: proxy-app
        identifiers:
          slug: cluster-proxy
        attrs:
          name: Cluster Proxy
          meta_icon: "/application-icons/proxy.svg"
          meta_description: "Forward Auth Proxy for Ninekube services"
          open_in_new_tab: false
          provider: !KeyOf proxy-provider

      # ─── PROXY OUTPOST ──────────────────────────────────────────────────
      - model: authentik_outposts.outpost
        id: proxy-outpost
        identifiers:
          name: Proxy Outpost
        attrs:
          type: proxy
          providers:
            - !KeyOf proxy-provider

      # ─── EMBEDDED OUTPOST (add proxy provider) ──────────────────────────
      - model: authentik_outposts.outpost
        identifiers:
          name: authentik Embedded Outpost
        attrs:
          providers:
            - !KeyOf proxy-provider
          _config:
            authentik_host: "https://authentik.${DOMAIN}"
            authentik_host_browser: "https://authentik.${DOMAIN}"

      # ─── LDAP SERVICE ACCOUNT ───────────────────────────────────────────
      - model: authentik_core.user
        id: ldapservice
        identifiers:
          username: ldapservice
        attrs:
          name: "LDAP Service Account"
          email: "ldapservice@${DOMAIN}"
          is_active: true
          type: service_account
          password: "${LDAP_PASS}"

      # ─── LDAP SEARCH ROLE ───────────────────────────────────────────────
      - model: authentik_rbac.role
        id: ldap-search-role
        identifiers:
          name: "LDAP Search"

      # ─── USERS GROUP ────────────────────────────────────────────────────
      - model: authentik_core.group
        id: users-group
        identifiers:
          name: Users

      # ─── ADD ADMIN TO USERS GROUP ───────────────────────────────────────
      - model: authentik_core.group
        identifiers:
          name: Users
        attrs:
          users:
            - !Find [authentik_core.user, [username, "${ADMIN_USER}"]]

      # ─── ADD ADMIN TO ADMINS GROUP (superuser) ──────────────────────────
      - model: authentik_core.group
        identifiers:
          name: authentik Admins
        attrs:
          is_superuser: true
          users:
            - !Find [authentik_core.user, [username, "${ADMIN_USER}"]]
EOF
ok "blueprint: ${BLUEPRINT_NAME}"

done_ok "authentik predeploy"
