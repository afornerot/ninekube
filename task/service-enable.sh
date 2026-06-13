#!/bin/bash
source "$(dirname "$0")/helpers.sh"

SERVICE="${1:?Usage: service-enable SERVICE=<service>}"
SERVICES_DIR="${NINEKUBE_DIR}/services"
SERVICE_DIR="${SERVICES_DIR}/${SERVICE}"
KUSTOMIZE_FILE="${BASE_DIR}/kustomization.yaml"

header "ENABLE SERVICE: ${SERVICE}"

# Validate service exists
if [ ! -d "$SERVICE_DIR" ]; then
  done_ko "Service '${SERVICE}' not found in ${SERVICES_DIR}"
  exit 1
fi

# Check if already enabled
if [ -L "${BASE_DIR}/${SERVICE}" ]; then
  warn "Service '${SERVICE}' is already enabled"
else
  info "Creating symlink: base/${SERVICE} -> ../services/${SERVICE}/"
  ln -s "../services/${SERVICE}/" "${BASE_DIR}/${SERVICE}"
  ok "Symlink created"
fi

# Add to kustomization.yaml if not present
if grep -q "^  - ${SERVICE}$" "$KUSTOMIZE_FILE" 2>/dev/null; then
  warn "Service '${SERVICE}' already in kustomization.yaml"
else
  info "Adding '${SERVICE}' to base/kustomization.yaml"
  sed -i "/^resources:$/a\\  - ${SERVICE}" "$KUSTOMIZE_FILE"
  ok "Added to kustomization.yaml"
fi

# ─── AUTH CONFIGURATION ───────────────────────────────────────────────────────
AUTH_FILE="${SERVICE_DIR}/auth.yaml"
if [ -f "$AUTH_FILE" ]; then
  AUTH_METHOD=$(grep "^method:" "$AUTH_FILE" | awk '{print $2}' | tr -d '"' | tr -d "'")
  info "auth method: ${AUTH_METHOD}"

  if [ "$AUTH_METHOD" = "forward_auth" ]; then
    # Apply Traefik middleware for forward auth
    info "applying Traefik forwardAuth middleware..."
    kubectl apply -f "${NINEKUBE_DIR}/base/traefik/middleware-authentik.yaml" 2>&1 | indent
    ok "Traefik middleware applied"

    # Add middleware annotation to service ingress
    INGRESS_FILE="${SERVICE_DIR}/ingress.yaml"
    if [ -f "$INGRESS_FILE" ]; then
      if ! grep -q "traefik.ingress.kubernetes.io/router.middlewares" "$INGRESS_FILE"; then
        info "adding middleware annotation to ingress..."
        sed -i "/annotations:/a\\  traefik.ingress.kubernetes.io/router.middlewares: kube-system-authentik-forwardauth@kubernetescrd" "$INGRESS_FILE"
        ok "middleware annotation added"
      fi
    fi
  fi
fi

done_ok "Service '${SERVICE}' enabled"
hint "Run 'task service-deploy SERVICE=${SERVICE}' to deploy"
