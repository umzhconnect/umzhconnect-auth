# Secrets — plain now, sealed-secrets later

Three secrets are required, kept **out of the kustomization** during the
plain-secret phase so real credentials never get committed to git:

| Secret | Used by | Keys |
|---|---|---|
| `regcred` | image pulls (Deployment + Job) | `.dockerconfigjson` |
| `keycloak-admin` | Keycloak bootstrap admin + Terraform | `admin-username`, `admin-password` |
| `keycloak-db` | Keycloak → managed Postgres | `username`, `password` |

## Phase 1 — plain secrets (create imperatively, do NOT commit real values)

```bash
NS=auth
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# 1. Harbor image-pull secret
kubectl -n "$NS" create secret docker-registry regcred \
  --docker-server=harbor-registry.io.usz.ch \
  --docker-username='<harbor-robot-user>' \
  --docker-password='<harbor-robot-token>'

# 2. Keycloak bootstrap admin
kubectl -n "$NS" create secret generic keycloak-admin \
  --from-literal=admin-username='admin' \
  --from-literal=admin-password='<strong-password>'

# 3. Managed Postgres credentials
kubectl -n "$NS" create secret generic keycloak-db \
  --from-literal=username='<db-user>' \
  --from-literal=password='<db-password>'
```

Alternatively, fill in and apply the `*.secret.example.yaml` templates in this
folder — but treat them as scratch: don't commit them with real values.

## Phase 2 — sealed-secrets (safe to commit)

Once the sealed-secrets controller is installed in the cluster:

```bash
# Seal each plain secret (pipe the imperative output through kubeseal).
kubectl -n auth create secret generic keycloak-db \
  --from-literal=username='<db-user>' --from-literal=password='<db-password>' \
  --dry-run=client -o yaml \
  | kubeseal --format yaml --controller-namespace sealed-secrets \
  > keycloak-db.sealed.yaml
# ...repeat for regcred and keycloak-admin...
```

Then uncomment the `secrets/*.sealed.yaml` entries in
`../kustomization.yaml` so ArgoCD manages them from git.
