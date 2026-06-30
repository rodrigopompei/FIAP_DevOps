#!/usr/bin/env bash
# Build the five service images and push them to OCIR (OCI Registry), then create
# the image-pull secret OKE uses to pull them. Mirrors eks/01-ecr-push.sh.
#
# OCIR repo path:  <region-key>.ocir.io/<tenancy-namespace>/<repo>:<tag>
#   region-key       e.g. iad (Ashburn), gru (São Paulo), phx (Phoenix)
#   tenancy-namespace = object-storage namespace (oci os ns get)
#
# Auth: OCIR login uses your OCI username + an AUTH TOKEN (not your password).
#   Create one: Console -> your profile -> Auth Tokens -> Generate Token.
#   export OCIR_USER='<tenancy-namespace>/<oci-username>'   (federated: '<ns>/oracleidentitycloudservice/<user>')
#   export OCIR_TOKEN='<auth-token>'
#
# Prereqs: docker, oci CLI, OCI_COMPARTMENT_OCID, kubectl context = OKE.
#
#   ./02-ocir-push.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"   # repo root holding each <svc>/ source folder
# Source code lives under Todos/<svc>; resolve that:
SRC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"  # the Todos/ folder

REGION="${OCI_REGION:-us-ashburn-1}"
REGION_KEY="${OCIR_REGION_KEY:-iad}"          # CHANGE to match your region (iad/gru/phx/...)
NS_OBJ="${OCIR_NAMESPACE:-$(command oci --region "$REGION" os ns get --query 'data' --raw-output)}"
REGISTRY="${REGION_KEY}.ocir.io/${NS_OBJ}"
TAG="${TAG:-latest}"
K8S_NS=togglemaster
PULL_SECRET=ocirsecret

SERVICES=(auth-service flag-service targeting-service evaluation-service analytics-service)

echo ">> Registry: $REGISTRY   Tag: $TAG"

echo ">> Logging in to OCIR"
echo "${OCIR_TOKEN:?export OCIR_TOKEN (an OCI auth token)}" \
  | docker login "${REGION_KEY}.ocir.io" -u "${OCIR_USER:?export OCIR_USER as <namespace>/<user>}" --password-stdin

for svc in "${SERVICES[@]}"; do
  uri="${REGISTRY}/togglemaster-${svc}:${TAG}"
  # analytics uses the OCI-specific Dockerfile (OCI Queue consumer + NoSQL writer);
  # everyone else uses the existing Dockerfile.k8s.
  dockerfile="Dockerfile.k8s"
  [ "$svc" = "analytics-service" ] && dockerfile="Dockerfile.oci"
  echo ">> Building & pushing $uri  (from $svc/$dockerfile)"
  docker build -f "$SRC_ROOT/$svc/$dockerfile" -t "$uri" "$SRC_ROOT/$svc"
  docker push "$uri"
done

echo ">> Creating image-pull secret '$PULL_SECRET' in ns/$K8S_NS"
kubectl create namespace "$K8S_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$K8S_NS" create secret docker-registry "$PULL_SECRET" \
  --docker-server="${REGION_KEY}.ocir.io" \
  --docker-username="$OCIR_USER" \
  --docker-password="$OCIR_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo ">> Done. Image URIs (used by 03-deploy-oci.sh):"
for svc in "${SERVICES[@]}"; do echo "   $svc -> ${REGISTRY}/togglemaster-${svc}:${TAG}"; done
echo
echo "   export OCIR_REGISTRY=$REGISTRY ; export TAG=$TAG"
echo "Next: ./03-deploy-oci.sh"
