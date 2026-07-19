#!/bin/bash
source "$(dirname "$0")/helpers.sh"

IMAGE="ghcr.io/afornerot/nextcloud-custom:latest"
DOCKERFILE_DIR="${NINEKUBE_DIR}/misc/docker/nextcloud"

header "BUILD NEXTCLOUD CUSTOM"

info "building image..."
docker build -t "$IMAGE" -f "${DOCKERFILE_DIR}/Dockerfile" "${DOCKERFILE_DIR}" 2>&1 | indent
ok "image built: ${IMAGE}"

info "pushing to GHCR..."
docker push "$IMAGE" 2>&1 | indent
ok "image pushed"

done_ok "nextcloud-custom image ready"
