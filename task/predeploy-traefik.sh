#!/bin/bash
source "$(dirname "$0")/helpers.sh"

header "PREDEPLOY TRAEFIK"

CURRENT_ARGS=$(kubectl get deployment traefik -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)

if echo "$CURRENT_ARGS" | grep -q "redirections.entryPoint.to=websecure"; then
  dim "HTTP->HTTPS redirect already configured"
else
  info "patching Traefik deployment..."
  kubectl patch deployment traefik -n kube-system --type='json' -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/args/3","value":"--entryPoints.websecure.address=:443/tcp"},
    {"op":"replace","path":"/spec/template/spec/containers/0/ports/3/containerPort","value":443},
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--entryPoints.web.http.redirections.entryPoint.to=websecure"},
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--entryPoints.web.http.redirections.entryPoint.scheme=https"}
  ]' 2>&1 | indent
  kubectl rollout status deployment/traefik -n kube-system --timeout=60s 2>&1 | indent
  ok "Traefik HTTP->HTTPS redirect configured"
fi

done_ok "traefik predeploy"
