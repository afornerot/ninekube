#!/bin/bash
source "$(dirname "$0")/helpers.sh"

header "BUILD NINEGATE (local)"

NINEGATE_DIR="${NINEKUBE_DIR}/../ninegate"
IMAGE="ghcr.io/afornerot/ninegate:main"

info "building ninegate image (no cache)..."
docker build --no-cache -t "$IMAGE" -f "${NINEGATE_DIR}/misc/docker/Dockerfile" "${NINEKUBE_DIR}/../ninegate" 2>&1 | indent

info "importing into k3s (need sudo)..."
docker save "$IMAGE" | sudo k3s ctr images import - 2>&1 | indent

info "restarting ninegate deployment..."
kubectl -n nine rollout restart deployment ninegate 2>&1 | indent
kubectl -n nine rollout status deployment ninegate --timeout=120s 2>&1 | indent
ok "ninegate restarted"
