#!/bin/bash
source "$(dirname "$0")/helpers.sh"

header "LOGS"

# Get logs from operator
section "Operator Logs"
kubectl logs -n ninekube-system -l app.kubernetes.io/name=ninekube-operator --tail=50 -c manager 2>/dev/null | indent
echo ""

# Get logs from each client namespace
for cn in $(cn_list 2>/dev/null); do
  ns=$(cn_namespace "$cn")
  [ -z "$ns" ] && continue

  section "Logs: $cn ($ns)"
  kubectl logs -n "$ns" -l app.kubernetes.io/part-of=ninekube --tail=20 --all-containers 2>/dev/null | indent
  echo ""
done

done_ok "logs complete"
