# ToggleMaster on Oracle Cloud (OKE)

This folder replicates the EKS deployment on **Oracle Kubernetes Engine (OKE)**,
swapping every AWS-specific dependency for its OCI equivalent.

## What changed vs. AWS/EKS

| Concern | AWS / EKS | OCI / OKE |
|---|---|---|
| Cluster | EKS via `eksctl` | OKE via `oci` CLI (`00-provision-oke.sh`) |
| Container registry | ECR | **OCIR** (`02-ocir-push.sh`) |
| Block storage | EBS CSI, `gp3`, 1Gi PVCs | **Block Volume CSI**, `oci-bv`, **50Gi** PVCs (OCI minimum) |
| Ingress LB | nginx-ingress + AWS NLB (hostname) | nginx-ingress + **OCI Flexible LB** (public IP) |
| Async messaging | **SQS** (eval → analytics) | **OCI Queue** |
| Analytics store | **DynamoDB** | **OCI NoSQL** |
| Cloud auth | static keys in `aws-credentials` secret | **instance principals** (keyless) — dynamic group + policy |

The five microservices, three Postgres StatefulSets, Redis, ConfigMaps/Secrets,
and host-based nip.io routing are otherwise identical.

## Code changes (kept backward-compatible with EKS)

- **evaluation-service** (Go): introduced an `EventPublisher` interface
  (`publisher.go`). The backend is chosen at runtime by `EVENT_BACKEND`:
  `sqs` (default, unchanged AWS behavior) or `ociqueue` (`oci_queue.go`). The
  EKS deployment is unaffected because the default stays `sqs`.
- **analytics-service** (Python): added `app_oci.py` (+ `requirements-oci.txt`,
  `Dockerfile.oci`) that consumes from OCI Queue and writes to OCI NoSQL. The
  original `app.py` (SQS + DynamoDB) is untouched.

## Prerequisites

- `oci` CLI configured (`oci setup config`) with rights to create networking,
  OKE, OCIR repos, Queue, NoSQL, and (for keyless auth) tenancy-level dynamic
  groups + policies. The identity bits may need a tenancy admin.
- `kubectl`, `docker`.
- An OCI **auth token** for OCIR login (Console → Profile → Auth Tokens).

## Run order

```bash
export OCI_COMPARTMENT_OCID=ocid1.compartment.oc1..xxxx
export OCI_REGION=us-ashburn-1            # and set OCIR_REGION_KEY to match (iad)

# 1) Cluster + networking + node pool + kubeconfig
./00-provision-oke.sh

# 2) OCI Queue + OCI NoSQL + keyless auth (dynamic group + policy)
./01-provision-queue-nosql.sh
#    -> exports OCI_QUEUE_ID, OCI_QUEUE_MESSAGES_ENDPOINT, OCI_NOSQL_TABLE

# 3) Build + push images to OCIR, create the image-pull secret
export OCIR_REGION_KEY=iad
export OCIR_USER='<tenancy-namespace>/<oci-username>'
export OCIR_TOKEN='<auth-token>'
./02-ocir-push.sh
#    -> exports OCIR_REGISTRY, TAG

# 4) Deploy everything (reuses base manifests + OCI overrides)
./03-deploy-oci.sh

# 5) Expose via OCI load balancer + nip.io ingress
./04-ingress-nip.sh
```

## Post-deploy seeding (same gotcha as EKS)

The auth DB starts **empty**, so the evaluation-service API key must be seeded or
flag evaluations return 401→500 (exactly the bug we hit on EKS). `03-deploy-oci.sh`
prints the one-liner; in short:

```bash
SERVICE_API_KEY=$(kubectl -n togglemaster get secret evaluation-service-secret \
  -o jsonpath='{.data.SERVICE_API_KEY}' | base64 -d)
HASH=$(printf '%s' "$SERVICE_API_KEY" | sha256sum | awk '{print $1}')
kubectl -n togglemaster exec auth-db-0 -c postgres -- psql -U auth_db -d auth_db \
  -c "INSERT INTO api_keys(name,key_hash,is_active) VALUES('evaluation-service','$HASH',true) ON CONFLICT (key_hash) DO NOTHING;"
```

Then seed your flags/targeting rules as needed.

## Verify

```bash
# health of each service (IP printed by 04-ingress-nip.sh)
curl http://auth.<IP>.nip.io/health
# full evaluation (producer -> OCI Queue -> analytics consumer -> OCI NoSQL)
curl "http://eval.<IP>.nip.io/evaluate?user_id=user-123&flag_name=enable-new-dashboard"

# confirm the analytics worker wrote to OCI NoSQL
oci nosql query execute --compartment-id "$OCI_COMPARTMENT_OCID" \
  --statement "SELECT * FROM ToggleMasterAnalytics"
```

## Notes / trade-offs

- **Keyless auth** uses instance principals scoped to *all instances in the
  compartment*. For tighter scoping, switch the dynamic group rule to match a
  node-pool tag, or move to OKE Workload Identity (requires enhanced cluster,
  already provisioned here).
- **`oci-bv` 50Gi minimum** is an OCI hard floor; the StatefulSets request 50Gi
  accordingly. Don't lower it or PVCs stay `Pending`.
- The EKS folder (`../eks`) is unchanged and still works; nothing here mutates
  the AWS path.
