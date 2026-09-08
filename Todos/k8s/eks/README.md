# ToggleMaster on Amazon EKS (AWS Academy Learner Lab)

Deploys the same stack as the Docker Desktop setup (`../README.md`) to a managed
EKS cluster, adapted for Learner Lab's constraints. The original per-service
manifests in `k8s/<svc>/` are reused as-is; only the cluster, image source, and
ingress differ, and those live here in `k8s/eks/`.

## What's different from Docker Desktop, and why

| Concern        | Docker Desktop                  | EKS / Learner Lab                                         |
|----------------|---------------------------------|-----------------------------------------------------------|
| Images         | built locally, `IfNotPresent`   | **must be pushed to ECR**; nodes can't see your daemon    |
| IAM            | n/a                             | only `LabRole`; **no role/OIDC creation** allowed         |
| PVC storage    | Docker Desktop provisioner      | `aws-ebs-csi-driver` addon (runs off LabRole)             |
| Ingress DNS    | `*.toggle.local` in `/etc/hosts`| nip.io off the ELB IP (no DNS setup)                      |
| AWS creds      | static-ish lab creds in secret  | **expire every session** — refresh, or use the node role  |

## Prerequisites
`awscli`, `eksctl`, `kubectl`, `docker`, `dig`. Start the lab ("AWS Details" →
copy creds into `~/.aws/credentials`, or use the provided `aws_session`), then:

```bash
export AWS_REGION=us-east-1
aws sts get-caller-identity      # confirm you're in account 294296614030
```

## One-time per lab lifetime: create the cluster (~15–20 min)

```bash
eksctl create cluster -f k8s/eks/eksctl-cluster.yaml
kubectl get nodes                # should show 2 Ready nodes
```

If `eksctl` errors trying to create an IAM role, it means the LabRole ARN in
`eksctl-cluster.yaml` is wrong for your account — fix the account number and
retry. Learner Lab will never let it *create* a role.

## Deploy

```bash
chmod +x k8s/eks/*.sh

# 1. Build all five images and push to ECR
k8s/eks/01-ecr-push.sh

# 2. Apply manifests and repoint Deployments at the ECR images
k8s/eks/02-deploy-eks.sh

# 3. Expose via nginx ingress + nip.io
k8s/eks/03-ingress-nip.sh
```

`03` prints the reachable URLs, e.g. `http://eval.<ip>.nip.io/health`.

## Seed the API key (REQUIRED — fresh DB starts empty)

The auth DB's `init.sql` only creates an empty `api_keys` table; nothing seeds a
key. Until you register one, every flag evaluation returns **401**
(`flag-service retornou status 401`). Auth-service *generates* the key — you
can't choose it — so create one, then sync the returned value into the secret:

```bash
AUTH=http://auth.<ip>.nip.io        # from step 3 output

# MASTER_KEY is in k8s/auth-service/secrets.yaml (admin-secreto-123)
curl -s -X POST "$AUTH/admin/keys" \
  -H "Authorization: Bearer admin-secreto-123" \
  -H "Content-Type: application/json" \
  -d '{"name":"evaluation-service"}'
# -> {"name":"evaluation-service","key":"tm_key_...."}   (shown ONCE)
```

Put the returned `tm_key_...` into `SERVICE_API_KEY` in
`k8s/evaluation-service/secrets.yaml`, then:

```bash
kubectl apply -f k8s/evaluation-service/secrets.yaml
kubectl -n togglemaster rollout restart deployment/evaluation-service
```

Verify:

```bash
curl "http://eval.<ip>.nip.io/evaluate?user_id=user-123&flag_name=enable-new-dashboard"
```

## AWS credentials for SQS/DynamoDB — pick one

`shared/aws-credentials.yaml` holds **temporary** Learner Lab creds
(`ASIA…` + `AWS_SESSION_TOKEN`) that **expire when the lab session ends**.

- **Option A (default, matches existing setup):** each new session, paste the
  fresh `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` from
  "AWS Details" into `shared/aws-credentials.yaml`, then:
  ```bash
  kubectl apply -f k8s/shared/aws-credentials.yaml
  kubectl -n togglemaster rollout restart deployment/analytics-service deployment/evaluation-service
  ```

- **Option B (recommended — no refresh chore):** since the cluster is in the
  *same* account that owns the SQS queue and the nodes run with `LabRole`
  (which has SQS/DynamoDB access), **remove** the three `AWS_*` keys from
  `shared/aws-credentials.yaml`. The AWS SDK then falls back to the node's
  instance role via IMDS automatically — no expiring creds to manage. Confirm
  LabRole permits `sqs:SendMessage` to `pompei-fiap-sqs-fila` and the
  `ToggleMasterAnalytics` DynamoDB table.

## Every new session checklist
1. Start lab, refresh `~/.aws` creds, confirm account 294296614030.
2. If cluster was torn down: `eksctl create cluster -f …` again.
3. If using creds Option A: refresh `aws-credentials.yaml` + restart the two apps.
4. If the nip.io host stopped resolving: re-run `03-ingress-nip.sh`.

## Teardown
```bash
eksctl delete cluster -f k8s/eks/eksctl-cluster.yaml   # also removes the ELB/VPC
# ECR repos persist (and may incur tiny storage cost):
for s in auth flag targeting evaluation analytics; do
  aws ecr delete-repository --repository-name "togglemaster-${s}-service" --force --region us-east-1
done
```
