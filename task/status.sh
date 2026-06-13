#!/bin/bash
source "$(dirname "$0")/helpers.sh"

header "STATUS"

section "Traefik (kube-system)"
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik 2>/dev/null | indent
echo ""

section "Pods (nine)"
kubectl get pods -n nine 2>/dev/null | indent
echo ""

section "Services (nine)"
kubectl get svc -n nine 2>/dev/null | indent
echo ""

section "Ingress (nine)"
kubectl get ingress -n nine 2>/dev/null | indent
echo ""

section "PVC (nine)"
kubectl get pvc -n nine 2>/dev/null | indent
echo ""

section "Certificates"
kubectl get certificates -n nine --ignore-not-found 2>/dev/null | indent
echo ""

done_ok "status complete"
