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
| Namespace | `auth` |
| Keycloak mode | `start-dev` (matches the dev cluster) — see hardening note below |

## Images

Two images, both **rarely** built (never on client/scope changes):

| Image | Source | Rebuilt when | Notes |
|---|---|---|---|
| `…/keycloak` | `keycloak/` (repo) | KC upgrade / mapper change (rare) | Carries the FhirContextMapper — unavoidable custom build |
| `…/tf-provider-mirror` | `tf-provider-mirror/` (repo) | provider bump in `terraform/.terraform.lock.hcl` (rare) | `terraform:1.15` with the keycloak + vault providers baked in as a filesystem mirror, so the config Job's `terraform init` runs **offline**. See [Terraform provider fetch](#terraform-provider-fetch) |

Client/scope changes and `.tf` changes ship as ConfigMaps (a `git` commit) —
**no image build**.

> **Egress alternative:** on a network that *does* allow `registry.terraform.io`,
> skip `tf-provider-mirror` and point the Job's terraform image back at the stock
> `hashicorp/terraform:1.15` (via Harbor's Docker Hub proxy cache) in
> `kustomization.yaml`'s `images:` block.

## Layout

```
argocd-usz/argocd/          <- ArgoCD Application points here (kustomize root)
├── kustomization.yaml       # resources + 3 configMapGenerators + images
├── ns.yaml                  # Namespace: auth
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

Only the Keycloak image is custom. Build it on an **amd64 host** (the cluster is
amd64) with a plain `docker build`, then push:

```bash
REG=harbor-registry.io.usz.ch/prj-0011608-umzhc
TAG=$(git rev-parse --short HEAD)      # or a date/label; avoid a bare "latest" for real runs
docker login harbor-registry.io.usz.ch

docker build -t "$REG/keycloak:$TAG" -t "$REG/keycloak:latest" keycloak
docker push "$REG/keycloak:$TAG"
docker push "$REG/keycloak:latest"
```

(On a non-amd64 build host, add `--platform=linux/amd64`; a native amd64 build
is simplest and avoids the cross-arch pitfalls.)

If you push a specific `$TAG`, set it in [`argocd/kustomization.yaml`](argocd/kustomization.yaml)'s
`images:` block (`newTag:`) so the manifests reference exactly what you pushed.

The Job's terraform image (`tf-provider-mirror`) is built separately — see
[Terraform provider fetch](#terraform-provider-fetch) for its `docker build` +
push. It bakes the providers so `terraform init` runs offline.

## Step 2 — create the secrets (plain phase)

See [`argocd/secrets/README.md`](argocd/secrets/README.md). Summary:

```bash
NS=auth
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
kubectl -n auth rollout status deploy/keycloak
kubectl -n auth logs job/keycloak-config          # terraform apply → "Apply complete!"

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

Caching the terraform **image** in Harbor is necessary but **not sufficient**:
at runtime `terraform init` also downloads two **providers** from
`registry.terraform.io` (pinned in `terraform/.terraform.lock.hcl`):
`keycloak/keycloak 5.8.0` and `hashicorp/vault 4.8.0`. Harbor's container-image
cache does not serve those, so on a locked-down network the Job fails at
`terraform init` even though the image pulled fine.

**This deployment solves it by baking the providers into an image**
([`tf-provider-mirror/`](../tf-provider-mirror/)), so the Job's `terraform init`
runs **fully offline**:

- `tf-provider-mirror/Dockerfile` runs `terraform providers mirror
  -platform=linux_amd64` at build time (where egress exists) into `/providers`,
  and bakes a `terraformrc` that forces terraform to install **only** from that
  filesystem mirror (`direct { exclude = ["*/*/*"] }`).
- `kustomization.yaml`'s `images:` block points the Job's terraform image at
  `…/tf-provider-mirror` — no Job/manifest edit needed.

### Build & push the mirror image
Build-time needs registry egress (do it on a machine with proxy access);
runtime needs none. Rebuild **only** when the providers in the lock file change.

1. **If the proxy inspects TLS** (`fproxy.usz.ch`), export its root CA into
   `tf-provider-mirror/certs/` so the provider downloads verify (the `certs/*.crt`
   are gitignored; skip on a non-inspecting path):
   ```bash
   openssl s_client -connect registry.terraform.io:443 -proxy proxy.usz.ch:8080 -showcerts </dev/null 2>/dev/null \
     | openssl x509 -out tf-provider-mirror/certs/corp-ca.crt
   ```
2. Build (context = repo root):
   ```bash
   docker build -f tf-provider-mirror/Dockerfile \
     -t harbor-registry.io.usz.ch/prj-0011608-umzhc/tf-provider-mirror:1.15-mirror .
   ```
3. Verify it's offline (expect `keycloak/keycloak/5.8.0` + `hashicorp/vault/4.8.0`):
   ```bash
   docker run --rm --network none --entrypoint sh \
     harbor-registry.io.usz.ch/prj-0011608-umzhc/tf-provider-mirror:1.15-mirror \
     -c 'ls /providers/registry.terraform.io/*/*'
   ```
4. Push (and set the matching `newTag` in `kustomization.yaml`'s `images:` block):
   ```bash
   docker push harbor-registry.io.usz.ch/prj-0011608-umzhc/tf-provider-mirror:1.15-mirror
   ```

If `terraform init` ever reports a checksum mismatch, run `terraform providers
lock -platform=linux_amd64`, commit the refreshed lock, and rebuild the mirror.

### Alternatives (instead of the mirror image)
- **Allow egress** to `registry.terraform.io` (+ provider download hosts), and point the Job's terraform image back at the stock `hashicorp/terraform:1.15` via Harbor's proxy cache.
- **Internal Terraform provider mirror** (network-mirror protocol) — needs a registry that speaks it (Artifactory does; plain Harbor does not).

(The `vault` provider is only used by the deferred production Vault path; drop
it from `terraform/versions.tf` to shrink the mirror to just `keycloak/keycloak`.)

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
