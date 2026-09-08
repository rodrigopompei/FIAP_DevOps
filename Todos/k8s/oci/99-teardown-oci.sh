#!/usr/bin/env bash
# Tear down EVERYTHING this folder created on OCI, in safe reverse order.
#
# Ordering matters:
#   1. Kubernetes-created cloud resources must go FIRST, while the cluster is
#      still alive: the OCI Load Balancer (from the ingress Service) and the
#      Block Volumes (from the StatefulSet PVCs). If you delete the cluster
#      first, these orphan and then block the VCN/subnet deletion.
#   2. Node pool -> cluster.
#   3. VCN contents (subnets, internet gateway) -> VCN.
#   4. OCI Queue, OCI NoSQL table.
#   5. IAM policy + dynamic group.
#   6. OCIR repositories.
#
# Best-effort: continues past individual failures (no `set -e`). Re-run if a
# late step fails because an earlier async delete hadn't finished.
#
# Usage:
#   export OCI_COMPARTMENT_OCID=... ; export OCI_REGION=...
#   ./99-teardown-oci.sh            # interactive confirm
#   FORCE=1 ./99-teardown-oci.sh    # skip the prompt
#
set -uo pipefail

REGION="${OCI_REGION:-us-ashburn-1}"
COMPARTMENT="${OCI_COMPARTMENT_OCID:?export OCI_COMPARTMENT_OCID first}"
CLUSTER_NAME="${CLUSTER_NAME:-togglemaster}"
QUEUE_NAME="${QUEUE_NAME:-togglemaster-events}"
NOSQL_TABLE="${NOSQL_TABLE:-ToggleMasterAnalytics}"
DG_NAME="${DG_NAME:-togglemaster-nodes}"
POLICY_NAME="${POLICY_NAME:-togglemaster-workload-policy}"
NS=togglemaster
NS_INGRESS=ingress-nginx

oci() { command oci --region "$REGION" "$@"; }
have() { [ -n "${1:-}" ] && [ "$1" != "null" ]; }

if [ "${FORCE:-}" != "1" ] && [ "${1:-}" != "--yes" ]; then
  echo "This will PERMANENTLY DELETE the OKE cluster, VCN, OCI Queue, OCI NoSQL"
  echo "table, IAM policy/dynamic-group and OCIR repos in region $REGION."
  read -r -p "Type 'destroy' to continue: " ans
  [ "$ans" = "destroy" ] || { echo "Aborted."; exit 1; }
fi

# --- 1. Kubernetes-level cleanup (frees the OCI LB + block volumes) ----------
if kubectl cluster-info >/dev/null 2>&1; then
  echo ">> [k8s] Deleting ingress + ingress-nginx (frees the OCI load balancer)"
  kubectl delete ingress --all -n "$NS" --ignore-not-found
  kubectl delete namespace "$NS_INGRESS" --ignore-not-found --timeout=180s

  echo ">> [k8s] Deleting namespace $NS (frees block volumes via the CSI driver)"
  kubectl delete namespace "$NS" --ignore-not-found --timeout=300s

  echo ">> Waiting ~90s for the cloud-controller to delete the LB and CSI to delete volumes"
  sleep 90
else
  echo ">> [k8s] No reachable cluster context — skipping in-cluster cleanup."
  echo "   (If the LB/block volumes were never deleted, the VCN delete below may"
  echo "    fail; delete leftover LBs/volumes in the Console and re-run.)"
fi

# --- 2. Node pool then cluster ----------------------------------------------
CLUSTER_ID="$(oci ce cluster list -c "$COMPARTMENT" --name "$CLUSTER_NAME" \
  --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null)"
if have "$CLUSTER_ID"; then
  NP_ID="$(oci ce node-pool list -c "$COMPARTMENT" --cluster-id "$CLUSTER_ID" \
    --name "$CLUSTER_NAME-ng" --query 'data[0].id' --raw-output 2>/dev/null)"
  if have "$NP_ID"; then
    echo ">> Deleting node pool"
    oci ce node-pool delete --node-pool-id "$NP_ID" --force --wait-for-state DELETED || true
  fi
  echo ">> Deleting OKE cluster (several minutes)"
  oci ce cluster delete --cluster-id "$CLUSTER_ID" --force --wait-for-state DELETED || true
else
  echo ">> No ACTIVE cluster named $CLUSTER_NAME — skipping."
fi

# --- 3. VCN contents then VCN ------------------------------------------------
VCN_ID="$(oci network vcn list -c "$COMPARTMENT" --display-name "$CLUSTER_NAME-vcn" \
  --query 'data[0].id' --raw-output 2>/dev/null)"
if have "$VCN_ID"; then
  for sn in "$CLUSTER_NAME-nodes" "$CLUSTER_NAME-lb"; do
    SN_ID="$(oci network subnet list -c "$COMPARTMENT" --vcn-id "$VCN_ID" \
      --display-name "$sn" --query 'data[0].id' --raw-output 2>/dev/null)"
    if have "$SN_ID"; then
      echo ">> Deleting subnet $sn"
      oci network subnet delete --subnet-id "$SN_ID" --force --wait-for-state TERMINATED || true
    fi
  done
  IGW_ID="$(oci network internet-gateway list -c "$COMPARTMENT" --vcn-id "$VCN_ID" \
    --query 'data[0].id' --raw-output 2>/dev/null)"
  if have "$IGW_ID"; then
    echo ">> Deleting internet gateway"
    oci network internet-gateway delete --ig-id "$IGW_ID" --force --wait-for-state TERMINATED || true
  fi
  echo ">> Deleting VCN (default route table + security list go with it)"
  oci network vcn delete --vcn-id "$VCN_ID" --force --wait-for-state TERMINATED || {
    echo "   !! VCN delete failed — usually a leftover LB still references a subnet."
    echo "      Check: oci lb load-balancer list -c \$OCI_COMPARTMENT_OCID"
    echo "             oci nlb network-load-balancer list -c \$OCI_COMPARTMENT_OCID"
    echo "      Delete it, then re-run this script."; }
else
  echo ">> No VCN named $CLUSTER_NAME-vcn — skipping."
fi

# --- 4. OCI Queue + OCI NoSQL ------------------------------------------------
QUEUE_ID="$(oci queue queue list -c "$COMPARTMENT" --display-name "$QUEUE_NAME" \
  --lifecycle-state ACTIVE --query 'data.items[0].id' --raw-output 2>/dev/null)"
if have "$QUEUE_ID"; then
  echo ">> Deleting OCI Queue $QUEUE_NAME"
  oci queue queue delete --queue-id "$QUEUE_ID" --force --wait-for-state DELETED || true
fi

if oci nosql table get --table-name-or-id "$NOSQL_TABLE" -c "$COMPARTMENT" >/dev/null 2>&1; then
  echo ">> Deleting OCI NoSQL table $NOSQL_TABLE"
  oci nosql table delete --table-name-or-id "$NOSQL_TABLE" -c "$COMPARTMENT" --force || true
fi

# --- 5. IAM policy + dynamic group (tenancy root) ----------------------------
TENANCY_ID="$(oci iam compartment get --compartment-id "$COMPARTMENT" \
  --query 'data."compartment-id"' --raw-output 2>/dev/null)"
have "$TENANCY_ID" || TENANCY_ID="$COMPARTMENT"
POLICY_ID="$(oci iam policy list -c "$TENANCY_ID" \
  --query "data[?name=='$POLICY_NAME'].id | [0]" --raw-output 2>/dev/null)"
if have "$POLICY_ID"; then
  echo ">> Deleting IAM policy $POLICY_NAME"
  oci iam policy delete --policy-id "$POLICY_ID" --force || true
fi
DG_ID="$(oci iam dynamic-group list \
  --query "data[?name=='$DG_NAME'].id | [0]" --raw-output 2>/dev/null)"
if have "$DG_ID"; then
  echo ">> Deleting dynamic group $DG_NAME"
  oci iam dynamic-group delete --dynamic-group-id "$DG_ID" --force || true
fi

# --- 6. OCIR repositories ----------------------------------------------------
for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  repo="togglemaster-${svc}"
  RID="$(oci artifacts container repository list -c "$COMPARTMENT" \
    --display-name "$repo" --query 'data.items[0].id' --raw-output 2>/dev/null)"
  if have "$RID"; then
    echo ">> Deleting OCIR repo $repo"
    oci artifacts container repository delete --repository-id "$RID" --force || true
  fi
done

cat <<EOF

>> Teardown complete (best-effort).

   Verify nothing lingers (these would still incur cost):
     oci lb load-balancer list        -c $COMPARTMENT --query 'data[*]."display-name"'
     oci nlb network-load-balancer list -c $COMPARTMENT --query 'data.items[*]."display-name"'
     oci bv volume list               -c $COMPARTMENT --lifecycle-state AVAILABLE --query 'data[*]."display-name"'

   Block volumes only auto-delete if their PVC was removed while the cluster was
   alive (it was, if step 1 ran). Delete any leftovers above manually.

   Local: the kubeconfig context for '$CLUSTER_NAME' is now stale; remove with:
     kubectl config delete-context \$(kubectl config get-contexts -o name | grep $CLUSTER_NAME) 2>/dev/null || true
EOF
