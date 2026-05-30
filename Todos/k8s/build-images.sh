#!/usr/bin/env bash
# Builds the five service images locally so the Docker Desktop K8s cluster can find them.
# Run from anywhere; resolves paths from this script's location.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TAG="${TAG:-k8s}"

build() {
  local svc="$1"
  echo ">> Building togglemaster/${svc}:${TAG}"
  docker build \
    -f "$ROOT/$svc/Dockerfile.k8s" \
    -t "togglemaster/${svc}:${TAG}" \
    "$ROOT/$svc"
}

build auth-service
build flag-service
build targeting-service
build evaluation-service
build analytics-service

echo
echo "Done. Images:"
docker images --filter=reference="togglemaster/*:${TAG}"
