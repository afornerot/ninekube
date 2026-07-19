#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"
DOMAIN=$(config_get domain 'nine.local')
ADMIN_USER=$(config_get admin_username 'admin')
ADMIN_PASS=$(config_get admin_password 'changeme')
NEXTCLOUD_CLIENT_SECRET=$(config_get dex_nextcloud_client_secret '')
TFM_CLIENT_SECRET=$(config_get dex_tfm_client_secret '')
NINEGATE_CLIENT_SECRET=$(config_get dex_ninegate_client_secret '')
LDAP_BASE_DN="dc=$(echo "${DOMAIN}" | sed 's/\./,dc=/g')"

header "PREDEPLOY DEX"

# --- GENERATE SECRETS ---
if [ -z "$NEXTCLOUD_CLIENT_SECRET" ]; then
  NEXTCLOUD_CLIENT_SECRET=$(openssl rand -base64 32)
  config_set dex_nextcloud_client_secret "$NEXTCLOUD_CLIENT_SECRET"
  info "generated nextcloud oidc client secret"
fi

if [ -z "$TFM_CLIENT_SECRET" ]; then
  TFM_CLIENT_SECRET=$(openssl rand -base64 32)
  config_set dex_tfm_client_secret "$TFM_CLIENT_SECRET"
  info "generated tinyfilemanager oidc client secret"
fi

if [ -z "$NINEGATE_CLIENT_SECRET" ]; then
  NINEGATE_CLIENT_SECRET=$(openssl rand -base64 32)
  config_set dex_ninegate_client_secret "$NINEGATE_CLIENT_SECRET"
  info "generated ninegate oidc client secret"
fi

# --- DEX CONFIG ---
info "creating dex config secret..."
apply_manifest <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: dex-config
  namespace: nine
  labels:
    app.kubernetes.io/name: dex
    app.kubernetes.io/part-of: ninekube
type: Opaque
stringData:
  config.yaml: |
    issuer: https://dex.${DOMAIN}

    storage:
      type: sqlite3
      config:
        file: /var/dex/dex.db

    web:
      https: 0.0.0.0:5556
      tlsCert: /etc/dex/tls/tls.crt
      tlsKey: /etc/dex/tls/tls.key

    oauth2:
      responseTypes: ["code", "token", "id_token"]
      skipApprovalScreen: true
      alwaysShowLoginScreen: false
      passwordConnector: local

    expiry:
      deviceRequests: "5m"
      idTokens: "24h"
      authRequests: "24h"

    signer:
      type: local
      config:
        keysRotationPeriod: "6h"
        algorithm: RS256

    enablePasswordDB: false

    connectors:
      - type: ldap
        name: LDAP
        id: ldap
        config:
          host: glauth.nine.svc.cluster.local:3893
          insecureNoSSL: true
          insecureBindNoSSL: true
          bindDN: "cn=admin,ou=all,${LDAP_BASE_DN}"
          bindPW: "${ADMIN_PASS}"
          userSearch:
            baseDN: "ou=users,${LDAP_BASE_DN}"
            filter: "(objectClass=posixAccount)"
            username: cn
            idAttr: cn
            emailAttr: mail
            nameAttr: cn
          groupSearch:
            baseDN: "ou=groups,${LDAP_BASE_DN}"
            filter: "(objectClass=groupOfNames)"
            userMatchers:
              - userAttr: DN
                groupAttr: member
            nameAttr: cn

    staticClients:
      - id: nextcloud
        secret: "${NEXTCLOUD_CLIENT_SECRET}"
        name: Nextcloud
        redirectURIs:
          - "http://nextcloud.${DOMAIN}/apps/oidc_login/oidc"
          - "https://nextcloud.${DOMAIN}/apps/oidc_login/oidc"
      - id: tinyfilemanager
        secret: "${TFM_CLIENT_SECRET}"
        name: Tiny File Manager
        redirectURIs:
          - "https://files.${DOMAIN}/oauth2/callback"
      - id: ninegate
        secret: "${NINEGATE_CLIENT_SECRET}"
        name: Ninegate
        redirectURIs:
          - "https://ninegate.${DOMAIN}/callback"
EOF
ok "dex config"

# --- DEX TLS SECRET (self-signed for now) ---
info "creating dex tls secret..."
TLS_DIR=$(mktemp -d)
if ! kubectl get secret dex-tls -n nine >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -keyout "${TLS_DIR}/tls.key" -out "${TLS_DIR}/tls.crt" \
    -days 3650 -nodes -subj "/CN=dex.${DOMAIN}" 2>/dev/null
  kubectl create secret tls dex-tls \
    --namespace=nine \
    --cert="${TLS_DIR}/tls.crt" \
    --key="${TLS_DIR}/tls.key" \
    --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - 2>&1 | indent
  ok "dex-tls secret"
else
  info "dex-tls secret already exists"
fi
rm -rf "${TLS_DIR}"

done_ok "dex predeploy"
