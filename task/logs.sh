#!/bin/bash
source "$(dirname "$0")/helpers.sh"

header "LOGS"
kubectl logs -n nine --all-containers --tail=100 -l app.kubernetes.io/part-of=ninekube 2>&1 | indent
done_ok "logs displayed"
