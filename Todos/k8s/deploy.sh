#!/usr/bin/env bash
# End-to-end deploy: build images and apply every manifest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! kubectl config current-context >/dev/null 2>&1; then
  echo "No kubectl context set. Enable Kubernetes in Docker Desktop (Settings -> Kubernetes -> Apply & restart)."
  exit 1
fi
echo ">> Using kube context: $(kubectl config current-context)"

#bash "$SCRIPT_DIR/build-images.sh"

echo ">> Applying namespace"
kubectl apply -f "$SCRIPT_DIR/namespace.yaml"

echo ">> Applying shared resources (aws-credentials)"
kubectl apply -f "$SCRIPT_DIR/shared/"

# echo ">> Applying per-service manifests"
# for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
#   echo "   - $svc"
#   kubectl apply -f "$SCRIPT_DIR/$svc/"
# done

echo ">> Applying auth-service manifests"
for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  echo "   - $svc"
  kubectl apply -f "$SCRIPT_DIR/$svc/"
done

echo ">> Applying ingress"
kubectl apply -f "$SCRIPT_DIR/ingress.yaml"

# echo
# echo ">> Waiting for rollouts (databases first, then apps)"
# for ss in auth-db flag-db targeting-db; do
#   kubectl -n togglemaster rollout status statefulset/"$ss" --timeout=180s
# done
# kubectl -n togglemaster rollout status deployment/evaluation-redis --timeout=120s

# for d in auth-service flag-service targeting-service evaluation-service analytics-service; do
#   kubectl -n togglemaster rollout status deployment/"$d" --timeout=180s
# done

echo
echo ">> Waiting for rollouts (databases first, then apps"
for ss in auth-db flag-db targeting-db; do
  kubectl -n togglemaster rollout status statefulset/"$ss" --timeout=180s
done
# kubectl -n togglemaster rollout status deployment/evaluation-redis --timeout=120s

for d in auth-service flag-service targeting-service evaluation-service analytics-service; do
  kubectl -n togglemaster rollout status deployment/"$d" --timeout=180s
done

# echo
echo ">> Done. Pods:"
kubectl -n togglemaster get pods
echo
echo "Endpoints (after adding /etc/hosts entries):"
echo "  curl http://auth.toggle.local/health"
echo "  curl http://flags.toggle.local/health"
echo "  curl http://targeting.toggle.local/health"
echo "  curl http://eval.toggle.local/health"
echo "  curl http://analytics.toggle.local/health"
