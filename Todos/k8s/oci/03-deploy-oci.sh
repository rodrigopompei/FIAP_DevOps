#!/usr/bin/env bash
# Deploy ToggleMaster to OKE. Reuses the cloud-agnostic base manifests for the
# stateless services + DB credentials/init, and applies the OCI-specific
# overrides (oci-bv databases, OCI Queue/NoSQL config, OCIR images).
#
# Prereqs (export these — printed by scripts 00/01/02):
#   OCIR_REGISTRY            e.g. iad.ocir.io/mynamespace
#   TAG                      e.g. latest
#   OCI_REGION OCI_COMPARTMENT_OCID OCI_QUEUE_ID OCI_QUEUE_MESSAGES_ENDPOINT OCI_NOSQL_TABLE
#   kubectl context = your OKE cluster
#
#   ./03-deploy-oci.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # the k8s/ folder (base manifests)
M="$SCRIPT_DIR/manifests"
NS=togglemaster

: "${OCIR_REGISTRY:?export OCIR_REGISTRY (e.g. iad.ocir.io/mynamespace)}"
TAG="${TAG:-latest}"
: "${OCI_REGION:?}" ; : "${OCI_COMPARTMENT_OCID:?}"
: "${OCI_QUEUE_ID:?}" ; : "${OCI_QUEUE_MESSAGES_ENDPOINT:?}" ; : "${OCI_NOSQL_TABLE:?}"

echo ">> Context: $(kubectl config current-context)"

echo ">> Namespace"
kubectl apply -f "$K8S_DIR/namespace.yaml"

echo ">> Ensuring oci-bv StorageClass exists"
kubectl get storageclass oci-bv >/dev/null 2>&1 || kubectl apply -f "$M/storageclass.yaml"

echo ">> Generating oci-config ConfigMap from env"
kubectl -n "$NS" create configmap oci-config \
  --from-literal=OCI_REGION="$OCI_REGION" \
  --from-literal=OCI_COMPARTMENT_OCID="$OCI_COMPARTMENT_OCID" \
  --from-literal=OCI_QUEUE_ID="$OCI_QUEUE_ID" \
  --from-literal=OCI_QUEUE_MESSAGES_ENDPOINT="$OCI_QUEUE_MESSAGES_ENDPOINT" \
  --from-literal=OCI_NOSQL_TABLE="$OCI_NOSQL_TABLE" \
  --from-literal=OCI_AUTH="instance_principal" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- auth/flag/targeting: reuse base configmap+secrets+service deployment, ----
# --- but use the OCI (oci-bv, 50Gi) database StatefulSets. --------------------
for svc in auth-service flag-service targeting-service; do
  echo ">> $svc (config + secret + deployment, base)"
  kubectl apply -f "$K8S_DIR/$svc/configmap.yaml"
  kubectl apply -f "$K8S_DIR/$svc/secrets.yaml"
  kubectl apply -f "$K8S_DIR/$svc/deployment.yaml"
done
echo ">> OCI databases (oci-bv, 50Gi)"
kubectl apply -f "$M/db-auth.yaml" -f "$M/db-flag.yaml" -f "$M/db-targeting.yaml"

# --- redis (base, cloud-agnostic) --------------------------------------------
echo ">> evaluation-redis (base)"
kubectl apply -f "$K8S_DIR/evaluation-service/redis.yaml"

# --- eval + analytics: OCI manifests; eval still needs its base secret --------
echo ">> evaluation-service (OCI) + analytics-service (OCI)"
kubectl apply -f "$K8S_DIR/evaluation-service/secrets.yaml"   # SERVICE_API_KEY (reused)
kubectl apply -f "$M/evaluation-service.yaml"
kubectl apply -f "$M/analytics-service.yaml"

echo ">> Repointing Deployments at OCIR images"
for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  kubectl -n "$NS" set image "deployment/$svc" "$svc=${OCIR_REGISTRY}/togglemaster-${svc}:${TAG}"
done

echo ">> Waiting for databases"
for ss in auth-db flag-db targeting-db; do
  kubectl -n "$NS" rollout status "statefulset/$ss" --timeout=300s
done
echo ">> Waiting for app deployments"
for d in auth-service flag-service targeting-service evaluation-service analytics-service evaluation-redis; do
  kubectl -n "$NS" rollout status "deployment/$d" --timeout=300s
done

echo
kubectl -n "$NS" get pods
cat <<EOF

>> Deployed. Two reminders that carried over from the EKS run:
   1) auth DB starts EMPTY — seed the evaluation-service API key, e.g.:
        HASH=\$(printf '%s' "\$SERVICE_API_KEY" | sha256sum | awk '{print \$1}')
        kubectl -n $NS exec auth-db-0 -c postgres -- \\
          psql -U auth_db -d auth_db -c \\
          "INSERT INTO api_keys(name,key_hash,is_active) VALUES('evaluation-service','\$HASH',true) ON CONFLICT (key_hash) DO NOTHING;"
   2) seed flag/targeting data as needed.

Next: ./04-ingress-nip.sh  (exposes the services on an OCI load balancer)
EOF
