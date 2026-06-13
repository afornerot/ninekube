#!/bin/bash
source "$(dirname "$0")/helpers.sh"

ENV="${1:-dev}"

header "DELETE ${ENV^^}"
kubectl delete -k "overlays/${ENV}/" --ignore-not-found 2>&1 | indent
done_warn "${ENV} deleted"
