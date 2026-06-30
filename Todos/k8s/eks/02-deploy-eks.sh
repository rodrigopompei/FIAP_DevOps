#!/usr/bin/env bash
# Apply every ToggleMaster manifest to the EKS cluster, then repoint each
# Deployment at its ECR image. Leaves the original k8s/<svc>/*.yaml untouched
# (they still hardcode the local togglemaster/<svc>:k8s tag for Docker Desktop);
# we override the image at apply time with `kubectl set image`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # the k8s/ folder

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws-cli.aws sts get-caller-identity --query Account --output text)}"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
TAG="${TAG:-latest}"
NS=togglemaster

echo ">> Using context: $(kubectl config current-context)"

echo ">> Applying namespace + shared + per-service manifests + ingress"
kubectl apply -f "$K8S_DIR/namespace.yaml"
kubectl apply -f "$K8S_DIR/shared/"
for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  echo "   - $svc"
  kubectl apply -f "$K8S_DIR/$svc/"
done

echo ">> Repointing Deployments at ECR images"
for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  kubectl -n "$NS" set image "deployment/$svc" \
    "$svc=${REGISTRY}/togglemaster-${svc}:${TAG}"
done

echo ">> Waiting for databases"
for ss in auth-db flag-db targeting-db; do
  kubectl -n "$NS" rollout status "statefulset/$ss" --timeout=300s
done

echo ">> Waiting for app deployments"
for d in auth-service flag-service targeting-service evaluation-service analytics-service; do
  kubectl -n "$NS" rollout status "deployment/$d" --timeout=300s
done

echo
echo ">> Pods:"
kubectl -n "$NS" get pods
echo
echo "Next: run 03-ingress-nip.sh to expose the services, then seed the API key"
echo "(see eks/README.md — the auth DB starts empty, so /admin/keys must be re-run)."
