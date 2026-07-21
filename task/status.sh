#!/bin/bash
source "$(dirname "$0")/helpers.sh"

header "STATUS"

section "Client Namespaces"
kubectl get cn -o wide 2>/dev/null | indent
echo ""

# Iterate over each ClientNamespace
for cn in $(cn_list 2>/dev/null); do
  ns=$(cn_namespace "$cn")
  [ -z "$ns" ] && continue

  echo ""
  section "Client: $cn (namespace: $ns)"
  echo ""

  echo "  Pods:"
  kubectl get pods -n "$ns" 2>/dev/null | sed 's/^/    /' | indent
  echo ""

  echo "  Services:"
  kubectl get svc -n "$ns" 2>/dev/null | sed 's/^/    /' | indent
  echo ""

  echo "  Ingress:"
  kubectl get ingress -n "$ns" --ignore-not-found 2>/dev/null | sed 's/^/    /' | indent
  echo ""

  echo "  PVC:"
  kubectl get pvc -n "$ns" --ignore-not-found 2>/dev/null | sed 's/^/    /' | indent
  echo ""

  echo "  Secrets:"
  kubectl get secrets -n "$ns" --no-headers 2>/dev/null | sed 's/^/    /' | indent
  echo ""
done

section "Infrastructure"
echo "  Traefik:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik 2>/dev/null | sed 's/^/    /' | indent
echo ""

echo "  cert-manager:"
kubectl get pods -n cert-manager 2>/dev/null | sed 's/^/    /' | indent
echo ""

echo "  Longhorn:"
kubectl get pods -n longhorn-system 2>/dev/null | sed 's/^/    /' | indent
echo ""

echo "  Operator:"
kubectl get pods -n ninekube-system 2>/dev/null | sed 's/^/    /' | indent
echo ""

done_ok "status complete"
