#!/usr/bin/env bash
# Provision the OCI-native backends that replace AWS SQS + DynamoDB:
#   - OCI Queue   "togglemaster-events"      (replaces the SQS queue)
#   - OCI NoSQL   "ToggleMasterAnalytics"    (replaces the DynamoDB table)
# and the keyless auth that lets the pods reach them WITHOUT API keys:
#   - a dynamic group matching the OKE worker nodes (instance principals)
#   - a policy granting that group use of queues + nosql in the compartment
#
# Prereqs: oci CLI configured; OCI_COMPARTMENT_OCID exported.
# Identity resources (dynamic group / policy) are created at the TENANCY root,
# so your user needs permission to manage them (or ask an admin to run that part).
#
#   ./01-provision-queue-nosql.sh
#
set -euo pipefail

REGION="${OCI_REGION:-us-ashburn-1}"
COMPARTMENT="${OCI_COMPARTMENT_OCID:?export OCI_COMPARTMENT_OCID first}"
QUEUE_NAME="${QUEUE_NAME:-togglemaster-events}"
NOSQL_TABLE="${NOSQL_TABLE:-ToggleMasterAnalytics}"
DG_NAME="${DG_NAME:-togglemaster-nodes}"
POLICY_NAME="${POLICY_NAME:-togglemaster-workload-policy}"

oci() { command oci --region "$REGION" "$@"; }

TENANCY_ID="$(oci iam compartment get --compartment-id "$COMPARTMENT" \
  --query 'data."compartment-id"' --raw-output 2>/dev/null || true)"
# If COMPARTMENT is itself the tenancy, fall back to it.
[ -n "${TENANCY_ID:-}" ] && [ "$TENANCY_ID" != "null" ] || TENANCY_ID="$COMPARTMENT"
COMP_NAME="$(oci iam compartment get --compartment-id "$COMPARTMENT" \
  --query 'data.name' --raw-output 2>/dev/null || echo "")"

# ---- OCI Queue --------------------------------------------------------------
echo ">> OCI Queue: $QUEUE_NAME"
QUEUE_ID="$(oci queue queue list -c "$COMPARTMENT" --display-name "$QUEUE_NAME" \
  --lifecycle-state ACTIVE --query 'data.items[0].id' --raw-output 2>/dev/null || true)"
if [ -z "${QUEUE_ID:-}" ] || [ "$QUEUE_ID" = "null" ]; then
  QUEUE_ID="$(oci queue queue create -c "$COMPARTMENT" --display-name "$QUEUE_NAME" \
    --wait-for-state SUCCEEDED --query 'data.resources[0].identifier' --raw-output)"
fi
MSG_ENDPOINT="$(oci queue queue get --queue-id "$QUEUE_ID" \
  --query 'data."messages-endpoint"' --raw-output)"
echo "   queue id:      $QUEUE_ID"
echo "   msg endpoint:  $MSG_ENDPOINT"

# ---- OCI NoSQL table --------------------------------------------------------
# NOTE: 'timestamp' is reserved in OCI NoSQL DDL, so the column is event_timestamp.
echo ">> OCI NoSQL table: $NOSQL_TABLE"
TABLE_STATE="$(oci nosql table get --table-name-or-id "$NOSQL_TABLE" -c "$COMPARTMENT" \
  --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
if [ "$TABLE_STATE" != "ACTIVE" ]; then
  oci nosql table create -c "$COMPARTMENT" \
    --name "$NOSQL_TABLE" \
    --ddl-statement "CREATE TABLE IF NOT EXISTS $NOSQL_TABLE (event_id STRING, user_id STRING, flag_name STRING, result BOOLEAN, event_timestamp STRING, PRIMARY KEY(event_id))" \
    --table-limits '{"maxReadUnits":10,"maxWriteUnits":10,"maxStorageInGBs":1}' \
    --wait-for-state SUCCEEDED >/dev/null
fi
echo "   table:         $NOSQL_TABLE (ACTIVE)"

# ---- keyless auth: dynamic group + policy (instance principals) -------------
echo ">> Dynamic group: $DG_NAME (matches worker nodes in this compartment)"
DG_ID="$(oci iam dynamic-group list --query "data[?name=='$DG_NAME'].id | [0]" --raw-output 2>/dev/null || true)"
if [ -z "${DG_ID:-}" ] || [ "$DG_ID" = "null" ]; then
  oci iam dynamic-group create \
    --name "$DG_NAME" --description "ToggleMaster OKE worker nodes" \
    --matching-rule "ALL {instance.compartment.id = '$COMPARTMENT'}" >/dev/null \
    && echo "   created" \
    || echo "   !! could not create dynamic group (need tenancy admin) — create it manually"
fi

echo ">> Policy: $POLICY_NAME"
SCOPE="compartment $COMP_NAME"; [ -n "$COMP_NAME" ] || SCOPE="tenancy"
oci iam policy create -c "$TENANCY_ID" \
  --name "$POLICY_NAME" --description "ToggleMaster workloads -> Queue + NoSQL" \
  --statements '[
    "Allow dynamic-group '"$DG_NAME"' to use queues in '"$SCOPE"'",
    "Allow dynamic-group '"$DG_NAME"' to manage nosql-family in '"$SCOPE"'"
  ]' >/dev/null 2>&1 && echo "   created" || echo "   (policy exists or needs admin — verify manually)"

cat <<EOF

>> Backends ready. Feed these into manifests/oci-config.yaml (or export for 03-deploy):
   export OCI_QUEUE_ID=$QUEUE_ID
   export OCI_QUEUE_MESSAGES_ENDPOINT=$MSG_ENDPOINT
   export OCI_NOSQL_TABLE=$NOSQL_TABLE
   export OCI_COMPARTMENT_OCID=$COMPARTMENT
   export OCI_REGION=$REGION

Next: ./02-ocir-push.sh
EOF
