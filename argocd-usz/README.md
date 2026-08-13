# argocd-usz — USZ test deployment (auth-test.umzhconnect.ch)

Concrete ArgoCD/kustomize manifests to run this repo's Keycloak realm as a
**test** service in the USZ cluster. This is the argocd-template/ pattern
instantiated for one environment; see
[`ai-docs/argocd-template.md`](../ai-docs/argocd-template.md) and
[`argocd-template/README.md`](../argocd-template/README.md) for the general
model.

Config-delivery strategy here is **Approach 1 (`configMapGenerator`)** from
[`argocd-template/Config_deploy_approaches.md`](../argocd-template/Config_deploy_approaches.md):
the Terraform module and the client/scope YAML are shipped as ConfigMaps, not
baked into a `configurator` image — chosen to keep governed image builds to a
minimum. See ["Migration to Approach 4"](#migration-to-approach-4-standalone-data-as-code-repo)
below for how this is meant to evolve.

## This environment's choices

| Concern | Decision |
|---|---|
| Registry | Harbor: `harbor-registry.io.usz.ch/prj-0011608-umzhc` |
| Config delivery | **Approach 1** — `.tf` + client/scope YAML via `configMapGenerator`, run on the stock terraform image (no `configurator`/`tf-config` image) |
| Image delivery | **Manual push** (no CI yet) — build `linux/amd64`, push by hand |
| External host (clients / issuer) | `https://auth-test.umzhconnect.ch` — exposed outward, appears in token `iss`/`aud` (`KC_HOSTNAME`) |
| Internal host (ingress) | `auth.dev.umzhc.io.usz.ch` — what the nginx `Ingress` matches; the external host forwards here |
| Ingress / TLS | nginx `Ingress` + cert-manager (`clusterissuer-acme-nginx`) on the internal host; cert Secret `auth.dev.umzhc.io.usz.ch-cert` |
| Database | **External managed Postgres**, creds in a plain `keycloak-db` Secret (no in-cluster DB) |
| Secrets | Plain now (created out-of-band); migrate to sealed-secrets later |
| Namespace | `umzhc-auth-test` |
| Keycloak mode | `start-dev` (matches the dev cluster) — see hardening note below |

## Images

Only **one custom image** is built — Approach 1 removes the per-config-change
image entirely.

| Image | Source | Rebuilt when | Notes |
|---|---|---|---|
| `…/keycloak` | `keycloak/` (repo) | KC upgrade / mapper change (rare) | Carries the FhirContextMapper — unavoidable custom build |
| `hashicorp/terraform:1.9` | Docker Hub, via your Harbor **proxy cache** | never (stock) | Runs the config Job; repointed to Harbor in `kustomization.yaml` `images:` |

Client/scope changes and `.tf` changes ship as ConfigMaps (a `git` commit) —
**no image build**.

## Layout

```
argocd-usz/argocd/          <- ArgoCD Application points here (kustomize root)
├── kustomization.yaml       # resources + 3 configMapGenerators + images
├── namespace.yaml
├── keycloak.yaml            # Deployment + Service -> managed Postgres
├── keycloak-config-job.yaml # PostSync: stock terraform image, mounts the ConfigMaps
├── ingress.yaml
├── application.example.yaml
├── terraform/               # COPY of ../../terraform (see sync note)
├── keycloak-config/         # the data-as-code
│   ├── scopes.yaml
│   └── clients/*.yaml
└── secrets/                 # plain-secret templates (created out-of-band)
```

`terraform/` is a **copy** of `terraform/` — kustomize can't read
files outside its root, so the module lives in-tree. Re-sync when the module
changes:

```bash
cp terraform/*.tf terraform/.terraform.lock.hcl argocd-usz/argocd/terraform/
```

## Placeholders to replace before deploying

- `REPLACE_MANAGED_DB_HOST` — managed Postgres host in [`argocd/keycloak.yaml`](argocd/keycloak.yaml) `KC_DB_URL` (also adjust db name / `sslmode` if needed)
- `storageClassName: default` in [`argocd/keycloak-config-job.yaml`](argocd/keycloak-config-job.yaml) — set to a real StorageClass (`kubectl get storageclass`)
- The `hashicorp/terraform` `newName` in [`argocd/kustomization.yaml`](argocd/kustomization.yaml) — confirm your Harbor Docker Hub proxy-cache path
- `REPLACE_GIT_HOST` in [`argocd/application.example.yaml`](argocd/application.example.yaml)
- The example client in [`argocd/keycloak-config/clients/`](argocd/keycloak-config/clients/) — replace with real USZ client(s)

---

## Step 1 — build & push the Keycloak image (manual)

Only the Keycloak image is custom. You're on Apple Silicon (arm64); the
cluster is amd64, so **`--platform linux/amd64` is mandatory** or the pod
crash-loops with "exec format error".

```bash
REG=harbor-registry.io.usz.ch/prj-0011608-umzhc
TAG=$(git rev-parse --short HEAD)      # or a date/label; avoid a bare "latest" for real runs
docker login harbor-registry.io.usz.ch

docker buildx build --platform linux/amd64 \
  --target prodimage \
  -t "$REG/keycloak:$TAG" -t "$REG/keycloak:latest" \
  --push keycloak
```

If you push a specific `$TAG`, set it in [`argocd/kustomization.yaml`](argocd/kustomization.yaml)'s
`images:` block (`newTag:`) so the manifests reference exactly what you pushed.

The terraform image is not built — it's the stock `hashicorp/terraform:1.9`
pulled through Harbor's proxy cache (confirm the `newName` path in the
`images:` block). **But see [Terraform provider fetch](#terraform-provider-fetch)
— pulling that image is not by itself enough on a locked-down network.**

## Step 2 — create the secrets (plain phase)

See [`argocd/secrets/README.md`](argocd/secrets/README.md). Summary:

```bash
NS=umzhc-auth-test
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret docker-registry regcred \
  --docker-server=harbor-registry.io.usz.ch \
  --docker-username='<harbor-robot-user>' --docker-password='<harbor-robot-token>'

kubectl -n "$NS" create secret generic keycloak-admin \
  --from-literal=admin-username='admin' --from-literal=admin-password='<strong-password>'

kubectl -n "$NS" create secret generic keycloak-db \
  --from-literal=username='<db-user>' --from-literal=password='<db-password>'
```

## Step 3 — fill placeholders

Edit `KC_DB_URL` host, the StorageClass, and the Harbor terraform `newName`
(see the placeholder list above).

## Step 4 — deploy

**Via ArgoCD** (preferred): put [`argocd/application.example.yaml`](argocd/application.example.yaml)
(with `repoURL`/`targetRevision` filled in) into your app-of-apps. ArgoCD
applies the kustomization; the `keycloak-config` Job runs as a PostSync hook.

**Or directly**, to try it before wiring ArgoCD:

```bash
kubectl apply -k argocd-usz/argocd
# the PostSync Job hook only runs under ArgoCD; apply it manually here:
kubectl apply -f argocd-usz/argocd/keycloak-config-job.yaml
```

## Step 5 — verify

```bash
kubectl -n umzhc-auth-test rollout status deploy/keycloak
kubectl -n umzhc-auth-test logs job/keycloak-config          # terraform apply → "Apply complete!"

# From outside, via the external host that forwards to the internal ingress:
curl -s https://auth-test.umzhconnect.ch/realms/umzh-connect/.well-known/openid-configuration | jq .issuer
# expect: https://auth-test.umzhconnect.ch/realms/umzh-connect  (external name, from KC_HOSTNAME)

# To test the ingress directly by its internal host (e.g. from in-cluster),
# send the internal Host header to the ingress:
# curl -s -H 'Host: auth.dev.umzhc.io.usz.ch' https://<ingress-ip>/realms/umzh-connect/.well-known/openid-configuration
```

DNS / routing: `auth.dev.umzhc.io.usz.ch` must resolve to the nginx ingress
controller (internal), and cert-manager must be able to issue for it. The
**external** name `auth-test.umzhconnect.ch` is handled by the outer LB/proxy
that forwards to that internal host — its DNS and TLS are configured there,
not in these manifests.

## Terraform provider fetch

Caching the `hashicorp/terraform` **image** in Harbor is necessary but **not
sufficient**. At runtime `terraform init` also downloads two **providers** from
`registry.terraform.io` (pinned in `terraform/.terraform.lock.hcl`):
`keycloak/keycloak 5.8.0` and `hashicorp/vault 4.8.0`. That's a separate fetch
Harbor's container-image cache does not serve — so on a locked-down network the
Job fails at `terraform init` even though the image pulled fine. Resolve one of:

- **Allow egress** to `registry.terraform.io` (+ its provider download hosts) — nothing else to change.
- **Internal Terraform provider mirror** — point terraform at it via CLI config (`provider_installation { network_mirror }`); needs a registry that speaks the Terraform provider protocol (Artifactory does; plain Harbor does not).
- **Bake the providers into a small terraform image** (`RUN terraform init` at build, using the committed lock file) — reintroduces one *rare* custom image but makes the Job egress-free. Ask if you want this Dockerfile added.

(The `vault` provider is only used by the deferred production Vault path; if
you're not using it, removing it from `terraform/versions.tf` drops
one of the two downloads.)

---

## Onboarding a client

1. Add a `<client_id>.yaml` under [`argocd/keycloak-config/clients/`](argocd/keycloak-config/clients/)
   (see its README) — no implicit access, no file = no client.
2. Add its path to the `kc-clients` `configMapGenerator` in
   [`argocd/kustomization.yaml`](argocd/kustomization.yaml) — the one extra edit
   Approach 1 costs (kustomize can't glob a directory).
3. Commit / open a PR. On sync the ConfigMap's content hash changes → the
   PostSync Job re-runs → `terraform apply` reconciles the new client. State
   persists on the `tf-workspace` PVC, so re-runs are idempotent. **No image build.**

## Migration to Approach 4 (standalone data-as-code repo)

The plan is to start here (Approach 1, same repo) and later move the
data-as-code to its **own repo, cloned by the Job at runtime** (Approach 4).
Because the config file format never changes, this is one planned migration —
not a rewrite. When an *organisational* signal calls for it (onboarding needs
its own reviewers/access; the per-file `kc-clients` edit gets tedious; the
ConfigMap nears its ~1MiB etcd ceiling), do the split and the mechanism change
together, since you're touching the Job either way:

1. **Move** `argocd/keycloak-config/` (and, if you also want it out of the
   image path, `argocd/terraform/`) into the new data-as-code repo, unchanged.
2. In `keycloak-config-job.yaml`, **replace the three ConfigMap volumes** with
   an `initContainer` that `git clone`s that repo into an `emptyDir` shared
   with the terraform container (which then reads `keycloak-config/` and
   `terraform/` from it). Pin to a commit SHA for prod; branch HEAD is fine for
   dev/test.
3. **Add** a read-only git deploy key (Secret) + egress from the Job to the git
   host — the new runtime dependency Approach 1 deliberately avoided.
4. **Remove** the `configMapGenerator` blocks from `kustomization.yaml`.

Everything else — Keycloak, DB, ingress, secrets, the Terraform module itself —
is untouched. See
[`argocd-template/Config_deploy_approaches.md`](../argocd-template/Config_deploy_approaches.md) §4.

## Moving to sealed-secrets

See [`argocd/secrets/README.md`](argocd/secrets/README.md) — `kubeseal` each
plain Secret into a `SealedSecret`, drop the manifests in `argocd/secrets/`,
and uncomment their entries in the kustomization so ArgoCD manages them.

## Production hardening (when this graduates past "test")

- Keycloak `args: ["start", "--optimized"]` + `KC_HOSTNAME_STRICT: "true"`.
- Pin image tags (no `latest`); ideally add CI so the Keycloak image builds are governed and reproducible.
- Resolve the Terraform provider fetch deterministically (mirror or baked image) rather than live egress.
- A Terraform state backend (S3/Azure/GCS) instead of the PVC, if you want state off-cluster.
- Sealed-secrets (or an external secrets manager) for all three secrets.
