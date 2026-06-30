#!/usr/bin/env bash
# Provision an OKE (Oracle Kubernetes Engine) cluster that mirrors the EKS setup.
#
# Creates: VCN + internet gateway + route table + security list + two regional
# subnets (one for worker nodes, one for the load balancer), an ENHANCED OKE
# cluster (enhanced is required for some OCI features and is the modern default),
# a node pool, and a local kubeconfig.
#
# Prereqs:
#   - `oci` CLI installed and configured (oci setup config) OR running where an
#     instance/resource principal is available.
#   - `kubectl` installed.
#   - export OCI_COMPARTMENT_OCID=ocid1.compartment.oc1..xxxx   (REQUIRED)
#   - optionally export OCI_REGION (default: us-ashburn-1)
#
# Idempotency: this script is best-effort idempotent — it looks up existing
# resources by display-name before creating. Re-running after a partial failure
# generally continues where it left off.
#
#   ./00-provision-oke.sh
#
set -euo pipefail

# ---- config -----------------------------------------------------------------
REGION="${OCI_REGION:-us-ashburn-1}"
COMPARTMENT="${OCI_COMPARTMENT_OCID:?export OCI_COMPARTMENT_OCID first}"
CLUSTER_NAME="${CLUSTER_NAME:-togglemaster}"
K8S_VERSION="${K8S_VERSION:-}"                 # empty -> auto-pick latest supported (see below)
NODE_SHAPE="${NODE_SHAPE:-VM.Standard.E4.Flex}" # amd64 (matches the images)
NODE_OCPUS="${NODE_OCPUS:-2}"
NODE_MEM_GB="${NODE_MEM_GB:-16}"
NODE_COUNT="${NODE_COUNT:-2}"
VCN_CIDR="10.0.0.0/16"
NODE_SUBNET_CIDR="10.0.10.0/24"
LB_SUBNET_CIDR="10.0.20.0/24"

oci() { command oci --region "$REGION" "$@"; }
jqv() { python3 -c 'import sys,json;print(json.load(sys.stdin)'"$1"')'; }

echo ">> Region=$REGION  Cluster=$CLUSTER_NAME  Compartment=${COMPARTMENT:0:25}..."

# OKE-supported Kubernetes versions change over time; auto-pick the latest unless
# the caller pinned one. (List with: oci ce cluster-options get --cluster-option-id all)
if [ -z "$K8S_VERSION" ]; then
  K8S_VERSION="$(oci ce cluster-options get --cluster-option-id all \
    --query 'data."kubernetes-versions"[-1]' --raw-output)"
  [ -n "$K8S_VERSION" ] && [ "$K8S_VERSION" != "null" ] || {
    echo "!! Could not auto-detect a supported Kubernetes version"; exit 1; }
fi
echo ">> Kubernetes version: $K8S_VERSION"

# ---- find-or-create helpers -------------------------------------------------
find_vcn() {
  oci network vcn list -c "$COMPARTMENT" --display-name "$CLUSTER_NAME-vcn" \
    --query 'data[0].id' --raw-output 2>/dev/null || true
}

# ---- VCN --------------------------------------------------------------------
VCN_ID="$(find_vcn)"
if [ -z "${VCN_ID:-}" ] || [ "$VCN_ID" = "null" ]; then
  echo ">> Creating VCN"
  VCN_ID="$(oci network vcn create -c "$COMPARTMENT" --cidr-block "$VCN_CIDR" \
    --display-name "$CLUSTER_NAME-vcn" --dns-label togglemaster \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
else
  echo ">> Reusing VCN $VCN_ID"
fi

echo ">> Internet gateway"
IGW_ID="$(oci network internet-gateway list -c "$COMPARTMENT" --vcn-id "$VCN_ID" \
  --query 'data[0].id' --raw-output 2>/dev/null || true)"
if [ -z "${IGW_ID:-}" ] || [ "$IGW_ID" = "null" ]; then
  IGW_ID="$(oci network internet-gateway create -c "$COMPARTMENT" --vcn-id "$VCN_ID" \
    --is-enabled true --display-name "$CLUSTER_NAME-igw" \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
fi

echo ">> Route table (default -> IGW)"
RT_ID="$(oci network vcn get --vcn-id "$VCN_ID" --query 'data."default-route-table-id"' --raw-output)"
oci network route-table update --rt-id "$RT_ID" --force \
  --route-rules '[{"destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","networkEntityId":"'"$IGW_ID"'"}]' >/dev/null

echo ">> Security list (intra-VCN + 6443 + nodeports + 80/443 + ssh)"
SL_ID="$(oci network vcn get --vcn-id "$VCN_ID" --query 'data."default-security-list-id"' --raw-output)"
oci network security-list update --security-list-id "$SL_ID" --force \
  --egress-security-rules  '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]' \
  --ingress-security-rules '[
    {"source":"10.0.0.0/16","protocol":"all","isStateless":false},
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":6443,"max":6443}}},
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":30000,"max":32767}}},
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}}
  ]' >/dev/null

create_subnet() {  # $1=name $2=cidr
  local existing
  existing="$(oci network subnet list -c "$COMPARTMENT" --vcn-id "$VCN_ID" \
    --display-name "$1" --query 'data[0].id' --raw-output 2>/dev/null || true)"
  if [ -n "${existing:-}" ] && [ "$existing" != "null" ]; then echo "$existing"; return; fi
  oci network subnet create -c "$COMPARTMENT" --vcn-id "$VCN_ID" --cidr-block "$2" \
    --display-name "$1" --route-table-id "$RT_ID" --security-list-ids '["'"$SL_ID"'"]' \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output
}

echo ">> Subnets (nodes + load balancer)"
NODE_SUBNET_ID="$(create_subnet "$CLUSTER_NAME-nodes" "$NODE_SUBNET_CIDR")"
LB_SUBNET_ID="$(create_subnet "$CLUSTER_NAME-lb" "$LB_SUBNET_CIDR")"

# ---- OKE cluster ------------------------------------------------------------
CLUSTER_ID="$(oci ce cluster list -c "$COMPARTMENT" --name "$CLUSTER_NAME" \
  --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)"
if [ -z "${CLUSTER_ID:-}" ] || [ "$CLUSTER_ID" = "null" ]; then
  echo ">> Creating OKE cluster (this takes several minutes)"
  CLUSTER_ID="$(oci ce cluster create -c "$COMPARTMENT" --name "$CLUSTER_NAME" \
    --kubernetes-version "$K8S_VERSION" --vcn-id "$VCN_ID" --type ENHANCED_CLUSTER \
    --endpoint-subnet-id "$LB_SUBNET_ID" --endpoint-public-ip-enabled true \
    --service-lb-subnet-ids '["'"$LB_SUBNET_ID"'"]' \
    --wait-for-state SUCCEEDED --query 'data.resources[0].identifier' --raw-output)"
else
  echo ">> Reusing cluster $CLUSTER_ID"
fi

# ---- node pool --------------------------------------------------------------
echo ">> Discovering a node image for $NODE_SHAPE / $K8S_VERSION"
# VM.Standard.E4.Flex is x86_64, so exclude aarch64 (ARM) and GPU images — the
# sources list mixes all architectures and picking the wrong one fails with
# "Node shape and image are not compatible".
IMAGE_ID="$(oci ce node-pool-options get --node-pool-option-id all \
  --query "data.sources[?contains(\"source-name\", 'OKE-${K8S_VERSION#v}') && !contains(\"source-name\", 'aarch64') && !contains(\"source-name\", 'GPU')] | [0].\"image-id\"" \
  --raw-output 2>/dev/null || true)"
[ -n "${IMAGE_ID:-}" ] && [ "$IMAGE_ID" != "null" ] || {
  echo "!! Could not auto-pick a node image. List options with:"
  echo "   oci ce node-pool-options get --node-pool-option-id all"
  exit 1; }

NP_ID="$(oci ce node-pool list -c "$COMPARTMENT" --cluster-id "$CLUSTER_ID" \
  --name "$CLUSTER_NAME-ng" --query 'data[0].id' --raw-output 2>/dev/null || true)"
if [ -z "${NP_ID:-}" ] || [ "$NP_ID" = "null" ]; then
  echo ">> Creating node pool"
  AD="$(oci iam availability-domain list -c "$COMPARTMENT" --query 'data[0].name' --raw-output)"
  oci ce node-pool create -c "$COMPARTMENT" --cluster-id "$CLUSTER_ID" \
    --name "$CLUSTER_NAME-ng" --kubernetes-version "$K8S_VERSION" \
    --node-shape "$NODE_SHAPE" \
    --node-shape-config '{"ocpus":'"$NODE_OCPUS"',"memoryInGBs":'"$NODE_MEM_GB"'}' \
    --node-image-id "$IMAGE_ID" \
    --size "$NODE_COUNT" \
    --placement-configs '[{"availabilityDomain":"'"$AD"'","subnetId":"'"$NODE_SUBNET_ID"'"}]' \
    --wait-for-state SUCCEEDED >/dev/null
else
  echo ">> Reusing node pool $NP_ID"
fi

# ---- kubeconfig -------------------------------------------------------------
echo ">> Writing kubeconfig (~/.kube/config merged)"
oci ce cluster create-kubeconfig --cluster-id "$CLUSTER_ID" \
  --file "$HOME/.kube/config" --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT

echo
echo ">> Cluster ready. Context:"
kubectl config current-context || true
kubectl get nodes || true

cat <<EOF

>> Save these for the next scripts:
   export OCI_COMPARTMENT_OCID=$COMPARTMENT
   export OCI_REGION=$REGION
   export OKE_CLUSTER_ID=$CLUSTER_ID
   export OKE_NODE_POOL_ID=$(oci ce node-pool list -c "$COMPARTMENT" --cluster-id "$CLUSTER_ID" --name "$CLUSTER_NAME-ng" --query 'data[0].id' --raw-output 2>/dev/null || echo '<node-pool-id>')

Next: ./01-provision-queue-nosql.sh
EOF
