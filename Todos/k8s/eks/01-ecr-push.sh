#!/usr/bin/env bash
# Build the five service images and push them to ECR so EKS nodes can pull them.
# EKS nodes cannot see your local Docker daemon, so the local-image +
# imagePullPolicy:IfNotPresent approach from the Docker Desktop setup does NOT
# work here — every image must live in a registry.
#
# Run AFTER you've started the lab and have valid `aws` creds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"   # repo root that holds each <svc>/ folder

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws-cli.aws sts get-caller-identity --query Account --output text)}"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
TAG="${TAG:-latest}"

SERVICES=(auth-service flag-service targeting-service evaluation-service analytics-service)

echo ">> Account: $ACCOUNT_ID   Region: $AWS_REGION   Registry: $REGISTRY"

echo ">> Logging in to ECR"
aws-cli.aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

for svc in "${SERVICES[@]}"; do
  repo="togglemaster-${svc}"
  echo ">> Ensuring ECR repo: $repo"
  aws-cli.aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1 \
    || aws-cli.aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" >/dev/null

  uri="${REGISTRY}/${repo}:${TAG}"
  echo ">> Building & pushing $uri"
  docker build -f "$ROOT/$svc/Dockerfile.k8s" -t "$uri" "$ROOT/$svc"
  docker push "$uri"
done

echo
echo ">> Done. Image URIs (used by 02-deploy-eks.sh):"
for svc in "${SERVICES[@]}"; do
  echo "   $svc -> ${REGISTRY}/togglemaster-${svc}:${TAG}"
done
