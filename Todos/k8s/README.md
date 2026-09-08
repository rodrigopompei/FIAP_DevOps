# Togglemaster on Kubernetes (Docker Desktop)

Mirrors `docker-compose.yml` but splits each service from its database. Apps are
`Deployment`s, Postgres instances are `StatefulSet`s with PVCs, Redis is a
`Deployment`, and an Ingress fronts everything via host-based routing.

## Layout

Each service owns a folder; cluster-wide resources (namespace, ingress) live at
the top level.

```
k8s/
├── namespace.yaml                  # togglemaster namespace
├── ingress.yaml                    # host-based routing into all 5 services
├── build-images.sh                 # docker build each Dockerfile.k8s
├── deploy.sh                       # build + apply + wait for rollouts
├── auth-service/
│   ├── secrets.yaml                # auth-db creds + MASTER_KEY + DATABASE_URL
│   ├── configmap.yaml              # PORT + init.sql
│   ├── db.yaml                     # Postgres StatefulSet + Service
│   └── deployment.yaml             # auth-service Deployment + Service
├── flag-service/                   # (same shape)
├── targeting-service/              # (same shape)
├── evaluation-service/
│   ├── secrets.yaml                # SERVICE_API_KEY
│   ├── configmap.yaml              # PORT + REDIS_URL + sibling service URLs
│   ├── redis.yaml                  # Redis Deployment + Service
│   └── deployment.yaml
└── analytics-service/
    ├── secrets.yaml                # AWS credentials (ROTATE THESE)
    ├── configmap.yaml              # PORT + AWS_REGION + SQS + DynamoDB
    └── deployment.yaml             # no local DB
```

## Prerequisites

1. **Docker Desktop -> Settings -> Kubernetes -> Enable Kubernetes -> Apply & Restart.**
   Then confirm:
   ```bash
   kubectl config use-context docker-desktop
   kubectl cluster-info
   ```
2. **Install the nginx ingress controller** (one-time):
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml
   kubectl -n ingress-nginx wait --for=condition=available deployment/ingress-nginx-controller --timeout=180s
   ```
3. **Add hostnames to `/etc/hosts`** (sudo):
   ```
   127.0.0.1  auth.toggle.local flags.toggle.local targeting.toggle.local eval.toggle.local analytics.toggle.local
   ```

## Deploy

```bash
chmod +x k8s/build-images.sh k8s/deploy.sh
k8s/deploy.sh
```

The script builds the five images via each service's `Dockerfile.k8s`, applies
`namespace.yaml`, then every per-service folder, then `ingress.yaml`, and waits
for all rollouts. Docker Desktop's K8s shares the Docker daemon, so no registry
push is needed (`imagePullPolicy: IfNotPresent` + matching local tag).

## Verify

```bash
kubectl -n togglemaster get pods
curl http://auth.toggle.local/health
curl http://flags.toggle.local/health
curl http://targeting.toggle.local/health
curl http://eval.toggle.local/health
curl http://analytics.toggle.local/health
```

## Apply one service at a time

```bash
kubectl apply -f k8s/auth-service/
kubectl -n togglemaster rollout status deployment/auth-service
```

## Common operations

```bash
# Tail logs
kubectl -n togglemaster logs -f deploy/auth-service

# Exec into a DB
kubectl -n togglemaster exec -it statefulset/auth-db -- psql -U auth_db

# Restart an app after a code change (rebuild + rollout)
docker build -f auth-service/Dockerfile.k8s -t togglemaster/auth-service:k8s auth-service
kubectl -n togglemaster rollout restart deployment/auth-service

# Tear everything down (PVCs are kept)
kubectl delete namespace togglemaster

# Also delete persistent data
kubectl -n togglemaster delete pvc -l app=auth-db
```

## Notes

- **Rotate the AWS credentials** in `analytics-service/secrets.yaml`. They were
  committed in plain text in `analytics-service/.env`. Once rotated, replace
  the values in the secret and `kubectl apply -f k8s/analytics-service/` again.
- Init SQL lives inside each service's `configmap.yaml`. If you change a
  schema, update the corresponding `db/init.sql` and the configmap together.
- The Postgres StatefulSet sets `PGDATA=/var/lib/postgresql/data/pgdata`
  because the official image refuses to initdb into a non-empty mount root
  (the PVC owns the parent directory).
