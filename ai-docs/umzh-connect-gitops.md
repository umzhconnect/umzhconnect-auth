---
recap: "Dev Kubernetes/ArgoCD deployment record spanning three repos — this repo builds images only, tch-umzh-connect-gitops holds all ArgoCD/k8s manifests plus its own configurator/keycloak-config layer, tch-syseng-argocd-gitops holds the Application CR. Covers the compose-to-k8s translation, why config crosses the repo boundary as baked images rather than ConfigMaps, the gitops repo's own configurator image for deployment-specific client onboarding, and what's still outstanding."
keywords: [tch-umzh-connect-gitops, tch-syseng-argocd-gitops, argocd, kustomization.yaml, kgateway, Gateway, HTTPRoute, postgres-operator, postgresql.acid.zalan.do, umzh-connect namespace, auth.umzh.dev.example.com, tf-workspace, tf-config, configurator, configurator/Dockerfile, keycloak-config, ci-keycloak.yml, ci-token-validator.yml, ci-tf-config.yml, ci-jwks-server.yml, ci-configurator.yml, GHCR_PULL_TOKEN, allow_l1_debug_clients, argocd-image-updater, deploy key, write-back, trafficpolicy-ip-whitelist]
---

# UMZH Connect Auth Server — dev k8s deployment

Status as of 2026-07-24 (see "Update 2026-07-24" below for what changed
since the original 2026-07-03 write-up — the rest of this doc is otherwise
left as originally written). This doc is the resumable record of the dev
Kubernetes/ArgoCD deployment work spanning three repos. If you're picking
this up in a fresh session, read this file first — it has every decision,
exact name/value, file location, and what's still outstanding.

**End-user docs under `docs/` must not leak this repo split.** This repo is
public and reusable for deployments other than our own dev cluster. Anything
under `docs/` (use-cases, ADRs, etc.) is end-user facing and must describe
deployment generically — referencing only [`./argocd-template`](../argocd-template)
and this repo's own code/config, never this file, any other `ai-docs/*.md`
doc, or the concrete `the gitops repo` / `the ArgoCD-applications repo`
repo names. Those concrete repos and their image-updater/write-back wiring
are internal-deployment detail, recorded here for our own resumability, not
part of the reusable contract this repo exposes to other adopters.

**This repo builds images only.** All ArgoCD/k8s manifests live in the
separate **`tch-umzh-connect-gitops`** repo. That split happened after the
first version of this work (which put `argocd/` + `kustomization.yaml`
directly in this repo) — see "Why the gitops repo is separate" below for why.

---

## Update 2026-07-24: the gitops repo grew its own configurator layer

Everything above (and the sections below, except where noted) describes the
state as of 2026-07-03, when config crossed the repo boundary by baking
`keycloak/terraform` + `keycloak/config` from *this* repo into the
`tf-config` image. `tch-umzh-connect-gitops` has since gone one step
further and added its **own** config layer on top, for deployment-specific
clients that shouldn't live in this repo's own `keycloak/config/` at all:

- **`tch-umzh-connect-gitops` now has a top-level `configurator/` and
  `keycloak-config/`**, alongside `argocd/`. `configurator/Dockerfile` is
  `FROM ghcr.io/trifork/tch-umzh-connect-authentication-server-tf-config:latest`
  + `COPY keycloak-config/. /src/config` — it overwrites `/src/config` from
  the `tf-config` image with the gitops repo's own client/scope files. A new
  `ci-configurator.yml` (same shared `build-image.yml` template as the other
  four images) builds and pushes it as
  `ghcr.io/trifork/tch-umzh-connect-gitops-configurator`, triggered on
  changes under `configurator/**` or `keycloak-config/**`.
- Because the `configurator` Dockerfile's `FROM` pulls a *private* image
  from a *different* repo (this one), `GITHUB_TOKEN` alone can't authenticate
  (it only reads packages published by the calling repo) — `ci-configurator.yml`
  logs in with a PAT secret (`GHCR_PULL_TOKEN`, needs both `read:packages`
  and `write:packages` since the same login also pushes the built image).
- **`argocd/keycloak-config-job.yaml` now runs the `configurator` image
  directly**, not `tf-config` — both `/src/terraform` and `/src/config` are
  already present in it, so the copy step is just
  `cp -rf /src/terraform/. /workspace/terraform/` +
  `cp -rf /src/config/. /workspace/config/`. `argocd/kustomization.yaml`'s
  `images:` list now pins `...gitops-configurator` (by digest) instead of
  `...authentication-server-tf-config`.
- **`keycloak-config/clients/` currently has**: `hospital_a-l2.yaml`,
  `hospital_b-l2.yaml`, `hospital_c-l2.yaml` (mirroring this repo's own
  `keycloak/config/clients/`), plus two dev-deployment-only additions that
  live *only* in the gitops repo: `hospital_d-l2.yaml` (`enabled: false` — a
  disabled fake client kept around for exercising the
  [client-enabled-flag](../keycloak/config/clients) config path without a
  real hospital) and `usz-l1.yaml` (an `auth_level: "L1"` debug client,
  requested by USZ per [ADR 0004](../docs/adr/0004-reinstate-l1-debug-client.md)).
- `keycloak-config-job.yaml`'s Job env now sets
  `TF_VAR_allow_l1_debug_clients: "true"`, the opt-in ADR 0004 requires
  before Terraform will provision any `auth_level: "L1"` file — needed for
  `usz-l1.yaml` above to actually take effect.
- `hook-delete-policy` on the Job now reads `BeforeHookCreation` only —
  `HookSucceeded` is deliberately omitted, so the most recently finished
  Job (success or failure) stays inspectable until the next sync's
  `BeforeHookCreation` clears it out.
- `argocd-template/` in this repo has been updated to mirror this pattern
  (`configurator/Dockerfile`, top-level `keycloak-config/`, an
  `example_client-l1.yaml` demoing the ADR 0004 opt-in) — see
  [ai-docs/argocd-template.md](argocd-template.md).

Net effect: `keycloak-config-job.yaml` now runs the `configurator` image,
with this repo's own `tf-config` image one layer removed as its base —
giving deployment-specific clients (like `usz-l1.yaml` above) a place to
live without touching this repo's own `keycloak/config/`, and keeping
onboarding a single point of edit (add a file, rebuild the `configurator`
image) regardless of which repo the client belongs to.

---

## Goal

Stand up a **dev-only**, non-persistent-in-spirit Kubernetes deployment of
this repo's stack (Keycloak + FhirContextMapper, the Terraform realm config,
jwks-server, token-validator) on the shared dev cluster, wired through
ArgoCD, following the conventions in `tch-syseng-argocd-gitops`.

Not in scope: production deployment (this repo's prod story is still "config
snapshot, later" — unrelated to this work), CI hardening beyond what's needed
to get images into GHCR, dedicated AppProject / network policies / prod-grade
security hardening.

---

## Repo split

| Repo | Owns |
|---|---|
| `tch-umzh-connect-authentication-server` (this repo) | Dockerfiles + CI for all 4 published images; the Terraform/config source files those images package (`keycloak/terraform/`, `keycloak/config/`) |
| `tch-umzh-connect-gitops` | All ArgoCD/k8s manifests (`argocd/*.yaml`, `argocd/kustomization.yaml`) |
| `tch-syseng-argocd-gitops` | The `Application` CR that points ArgoCD at `tch-umzh-connect-gitops` |

### Why the gitops repo is separate, and how config crosses the boundary

The gitops repo has no read access to this repo's raw files (no shared
checkout at sync time), and this matters because `argocd-image-updater`'s
write-back needs a repo ArgoCD can push tag bumps to — mixing that with this
repo's own source would mean giving image-updater write access here too.
Confirmed against the ArgoCD docs: multi-source `$ref` substitution (which
lets one source reference another source's files) is Helm-`valueFiles`-only;
there's no equivalent for a kustomize source's `configMapGenerator` to reach
into a second git repo.

So instead of the gitops repo generating ConfigMaps from this repo's raw
`.tf`/YAML/JWKS files, this repo **bakes those files into two additional
images** and the gitops repo's manifests reference them by tag — exactly
like `keycloak`/`token-validator` already were:

- **`tf-config`** (`tf-config/Dockerfile`, `FROM hashicorp/terraform:1.9`) —
  `COPY keycloak/terraform /src/terraform`, `COPY keycloak/config /src/config`.
  The `keycloak-config` Job copies `/src/*` onto its `tf-workspace` PVC before
  running `terraform apply`, so `terraform.tfstate` still persists across Job
  re-runs even though the image itself is immutable per tag.
- **`jwks-server`** (`jwks-server/Dockerfile`, `FROM nginx:1.27-alpine`) —
  `COPY keys/.well-known/ /usr/share/nginx/html/.well-known/`.
  Bakes in only `keys/.well-known/` (the public JWKS files, served at
  `/.well-known/{client_id}.jwks.json`), never the demo private `.key`
  files that live directly under `keys/` — enforced by directory boundary
  at the Dockerfile level, not a curated ConfigMap file list.

Because the whole `keycloak/config` directory is baked in via `COPY`, there's
no manually-curated file list that can omit a file by mistake — onboarding a
new file is always a single point of edit (add it, rebuild the image).

---

## Decisions made (and why)

| Decision | Chosen | Why |
|---|---|---|
| Routing | **kgateway** (Gateway API: `Gateway` + `HTTPRoute`), not nginx `Ingress` | Dev cluster's convention for *new* apps is kgateway (nginx-ingress is kept only for legacy apps + ArgoCD's own UI). |
| CI | **Use the shared pipeline templates** where possible; `workflow_dispatch` required on every workflow | The shared containerized-build template could NOT be used for the GHCR publish jobs (see "CI constraints" below) — used bespoke `docker/build-push-action` jobs instead, but did use the shared SAST template for CodeQL. |
| Image naming | **One distinct image name per artifact**, bespoke publish jobs for each (not template, not shared-package-with-tag-prefix) | Cleanest option, avoids a naming smell that would've propagated into every manifest permanently. |
| Manifest location | **Separate `tch-umzh-connect-gitops` repo**, flat `argocd/` dir (no `base/`/`overlays/` split) | Dev-only deployment, no need for a base/overlays split. All ArgoCD config was later moved out of this repo entirely into the dedicated gitops repo, keeping only image-building + terraform changes here. |
| Config hand-off (gitops repo needs `.tf`/hospital/scopes/jwks files, but has no read access to this repo) | **Bake into two additional images** (`tf-config`, `jwks-server`), not a cross-repo kustomize reference | See "Why the gitops repo is separate" above — ArgoCD has no cross-repo kustomize mechanism, and reintroducing coupling via e.g. a remote kustomize base would need private-repo auth for kustomize itself and defeat the point of the split. |
| Persistence | Postgres: **5Gi PVC via Zalando postgres-operator's normal defaults** | Not literally ephemeral — the operator requires a volume by design, and TF state also needs to survive Job reruns (see below), so "don't care about persistence" was interpreted as "don't fight the tooling for zero durability", not "force emptyDir". |
| ArgoCD project / namespace | `project: default`, `destination.namespace: umzh-connect` | — |
| Public dev hostname | `auth.umzh.dev.example.com` | Originally `ucauth.dev.example.com`; all manifests, docs, and internal object names (`Gateway` listener names, TLS secret name) were renamed to match when changed. |
| jwks-server scope | Serve **only the public `*.jwks.json` files**, not the demo private `.key` files that local docker-compose also serves | Deviation from compose parity: serving private key material over HTTP in a shared cluster (even a throwaway one) is worse than doing so on `localhost`. Flagged in `ai-docs/infrastructure.md`. Now enforced by the `jwks-server` image's Dockerfile, not a file list. |
| Deploy keys | `tch-umzh-connect-gitops` gets its own write-capable deploy key for `argocd-image-updater`'s write-back, scoped to only that repo; this repo keeps (at most) a read-only key, no longer load-bearing for ArgoCD sync since the gitops repo now holds 100% of what ArgoCD reads | Least-privilege — a write-back credential should not be broad enough to also touch this repo, and vice versa. Key generation/rotation is managed outside this doc's scope. |

---

## Architecture: compose → k8s translation

| docker-compose service | k8s equivalent | Image built in this repo | Manifest (in `tch-umzh-connect-gitops`) |
|---|---|---|---|
| `postgres` | `postgresql.acid.zalan.do` CR (Zalando postgres-operator, already running in the dev cluster), 5Gi PVC. Operator auto-creates credentials Secret `keycloak.umzh-connect-db.credentials.postgresql.acid.zalan.do` (keys `username`, `password`) | — | `argocd/database.yaml` |
| `keycloak` | Deployment + Service, still `start-dev` (sandbox parity) | `keycloak/Dockerfile` | `argocd/keycloak.yaml` |
| `keycloak-config` (terraform apply) | k8s `Job`, ArgoCD `PostSync` hook, single container. Copies the `tf-config` image's baked-in `/src/terraform` + `/src/config` onto a persistent workspace PVC (`tf-workspace`, 1Gi) before `terraform apply`, so `terraform.tfstate` survives hook re-runs | `tf-config/Dockerfile` | `argocd/keycloak-config-job.yaml` |
| `jwks-server` | Deployment + Service; image bakes in only the public `*.jwks.json` files (see deviation above) | `jwks-server/Dockerfile` | `argocd/jwks-server.yaml` |
| `token-validator` | Deployment + Service | `token-validator/Dockerfile` | `argocd/token-validator.yaml` |
| N/A (new) | `Gateway` (kgateway) + `HTTPRoute` (+ https-redirect route) publishing Keycloak at `https://auth.umzh.dev.example.com` | — | `argocd/gateway.yaml`, `argocd/httproute.yaml` |
| N/A (new) | Namespace, GHCR pull secret (ExternalSecret from the org's secrets manager), dev-only Keycloak admin credentials (plain Secret, `admin`/`admin`, matches local `.env`) | — | `argocd/namespace.yaml`, `argocd/regcred.yaml`, `argocd/keycloak-admin-secret.yaml` |

Internal vs. external addressing mirrors the compose split
(`KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true`): the TF job and token-validator talk
to Keycloak via the in-cluster Service DNS `keycloak:8080`; the published
issuer (`KC_HOSTNAME`) and token-validator's `ISSUER` env are the public
`https://auth.umzh.dev.example.com`.

---

## Exact names/values (for cross-referencing manifests)

- Namespace: `umzh-connect`
- Keycloak Service: `keycloak`, ports `8080` (http), `9000` (management)
- Postgres cluster name: `umzh-connect-db`, teamId `umzh`, db `keycloak`, user `keycloak`
- Postgres credentials Secret (operator-managed): `keycloak.umzh-connect-db.credentials.postgresql.acid.zalan.do`
- Keycloak admin Secret: `keycloak-admin` (keys `admin-username`/`admin-password`, dev-only plaintext `admin`/`admin`)
- GHCR pull secret: `regcred` (ExternalSecret from the org's secrets manager) — now also mounted by `jwks-server` and `keycloak-config` (their images are private GHCR images too, unlike the old `nginx:1.27-alpine`/`alpine:3.20`/`hashicorp/terraform:1.9` public bases)
- jwks-server Service: `jwks-server`, port `80` — matches what's already baked into `keycloak/config/clients/hospital_{a,b}-l2.yaml` (`jwks_url: http://jwks-server/...`), confirmed by grep
- token-validator Service: `token-validator`, port `8086`
- TF workspace PVC: `tf-workspace` (1Gi), Job name `keycloak-config`
- Public dev issuer: `https://auth.umzh.dev.example.com` → `https://auth.umzh.dev.example.com/realms/umzh-connect`
- Gateway listener names: `auth-http` / `auth-https`; TLS cert secret: `tls-auth-umzh-dev-example-com-gateway`
- Images (all `ghcr.io/trifork/tch-umzh-connect-authentication-server-*`):
  - `-keycloak`
  - `-token-validator`
  - `-tf-config`
  - `-jwks`
- ArgoCD Application name: `umzh-connect-auth` (in `tch-syseng-argocd-gitops`, namespace `argocd`), `source.repoURL` = `tch-umzh-connect-gitops`, `source.path` = `argocd`

---

## Files created / modified

### This repo (`tch-umzh-connect-authentication-server`)

- `keycloak/Dockerfile` — final stage renamed to `AS prodimage`
- `token-validator/Dockerfile` — final stage renamed to `AS prodimage`
- `tf-config/Dockerfile` — new; packages `keycloak/terraform` + `keycloak/config`
- `jwks-server/Dockerfile` — new; packages the two public JWKS files
- `.github/workflows/ci-keycloak.yml` — new, bespoke build+push
- `.github/workflows/ci-token-validator.yml` — new, bespoke build+push
- `.github/workflows/ci-tf-config.yml` — new, bespoke build+push
- `.github/workflows/ci-jwks-server.yml` — new, bespoke build+push
- `.github/workflows/sast.yml` — new, uses shared SAST template, 2 jobs (`tf-config`/`jwks-server` have no app source, not scanned)
- `ai-docs/infrastructure.md` — rewritten "Dev k8s deployment (ArgoCD)" section to reflect the repo split + image-based config hand-off, refreshed `keywords` frontmatter
- Previously present, now removed: root `kustomization.yaml`, `argocd/*.yaml` (moved to `tch-umzh-connect-gitops`)

### `tch-umzh-connect-gitops` (new repo)

- `argocd/namespace.yaml`, `regcred.yaml`, `keycloak-admin-secret.yaml`, `database.yaml`, `keycloak.yaml`, `token-validator.yaml`, `gateway.yaml`, `httproute.yaml` — moved as-is from this repo
- `argocd/jwks-server.yaml` — rewritten: Deployment now references the `jwks-server` image directly (`imagePullSecrets: regcred` added since it's now a private image), no ConfigMap volume
- `argocd/keycloak-config-job.yaml` — rewritten: single container (no more alpine initContainer), image is `tf-config`, copies `/src/terraform` + `/src/config` onto the PVC, no ConfigMap volumes
- `argocd/kustomization.yaml` — new, lives inside `argocd/` (no root-level workaround needed, since this repo's own `configMapGenerator` constraint no longer applies once config crosses the repo boundary as baked images), `images:` block lists all 4 images

### `tch-syseng-argocd-gitops` (sibling repo)

- `argocd/overlays/dev/applications/umzh-connect-auth.yaml` — `source.repoURL` changed to `tch-umzh-connect-gitops`, `source.path` changed to `argocd`; `argocd-image-updater.argoproj.io/image-list` annotation extended to all 4 images
- `argocd/overlays/dev/applications/kustomization.yaml` — added `umzh-connect-auth.yaml` to `resources`

---

## CI constraints (why CI isn't using the shared containerized-build template for publish)

- The template's publish step hardcodes the GHCR image name to
  `ghcr.io/<owner>/<repo>` — no per-image override input. Multiple jobs with
  different project paths would still collide on the same package name
  (this repo publishes 4 distinct images).
- The template's auto-tag logic **skips publishing entirely on
  `main`/`master`** unless an explicit `tag:` input is passed — this repo's
  default branch is `main`, so a naive `workflow_dispatch` on the template
  would silently build-but-not-push.
- Resolution: all four `ci-*.yml` workflows use `docker/build-push-action`
  directly (same action versions as the template), with explicit per-image
  `tags:` and a `workflow_dispatch` input for an optional manual tag override
  (defaults to short SHA). `sast.yml` still uses the shared template since
  CodeQL isn't affected by the naming constraint, and doesn't apply to
  `tf-config`/`jwks-server` (no application source to scan).

---

## Verification already done (all passed)

```sh
# This repo — no more argocd/kustomization here, nothing to kustomize-build

# tch-umzh-connect-gitops — kustomize build must succeed
cd <path-to>/tch-umzh-connect-gitops/argocd
kubectl kustomize . > /tmp/gitops-rendered.yaml && echo OK
grep -n "image:" /tmp/gitops-rendered.yaml   # all 4 images present
grep -n "kind: ConfigMap" /tmp/gitops-rendered.yaml   # none — confirms no cross-repo file dependency remains

# ArgoCD gitops repo's dev applications kustomization must still build
cd <path-to>/tch-syseng-argocd-gitops/argocd/overlays/dev/applications
kubectl kustomize . > /tmp/apps.yaml && echo OK

# jwks_url values already match the in-cluster service name
grep -rn "jwks_url" keycloak/config/clients/

# No stray .tfvars files that would be missing from the tf-config image
ls keycloak/terraform/*.tfvars 2>/dev/null || echo none
```

What has **not** been verified (can't be, without cluster access / a real
sync / a Docker daemon): whether the `tf-config`/`jwks-server` images actually
build (no local Docker daemon available during this work — only the `COPY`
source paths were confirmed to exist), whether the Application actually
reconciles cleanly against the live dev cluster, whether the
postgres-operator's CRD schema in that specific cluster version accepts this
exact `postgresql` spec, whether kgateway's `GatewayClass` name is really
`kgateway` in that cluster (taken from another app's reference manifests on
the shared dev cluster, not independently re-verified against live cluster
state).

---

## What's still outstanding / next steps to resume

1. **Nothing has been pushed to GHCR yet.** Trigger all four `ci-*.yml`
   workflows via `workflow_dispatch` to get the first images published — the
   Deployments will `ImagePullBackOff` until then. `ci-tf-config.yml` and
   `ci-jwks-server.yml` have never run — first run doubles as the build
   verification that couldn't be done locally (no Docker daemon).
2. **The ArgoCD `Application` has not been synced** — confirm before pushing
   any of the three repos' changes, since this affects a shared cluster.
   `ci-*.yml`'s `push` triggers and ArgoCD's auto-sync will start acting the
   moment `main` gets these changes in each repo.
3. **Deploy keys**: a write-capable deploy key scoped to
   `tch-umzh-connect-gitops` for `argocd-image-updater`'s write-back, ideally
   referenced per-Application via a per-app write-back secret annotation
   rather than the global image-updater secret.
4. **Not independently verified against the live cluster**: exact
   `GatewayClass` name (`kgateway`), postgres-operator CRD schema
   compatibility, and whether the GHCR pull-secret's source path and
   ClusterSecretStore are reachable from the `umzh-connect` namespace (they
   should be, per convention, but wasn't checked directly).
5. **No container vulnerability scanning (Trivy)** on the four bespoke CI
   workflows — the shared template includes this for free; going bespoke
   traded it away. Could be added later as a follow-up if wanted.
6. **Terraform state durability is Job/PVC-based, not battle-tested.** First
   real PostSync run will tell us if the copy-from-image + PVC-state approach
   actually round-trips correctly end-to-end (kustomize build correctness was
   verified; runtime behavior was not, since that requires a live cluster).

---

## Job/hook details worth keeping in mind

- The `keycloak-config` Job's `name` is fixed (not generated) since it's a
  PostSync hook — ArgoCD matches hooks across syncs by name.
- `hook-delete-policy` must be set explicitly to `BeforeHookCreation`:
  specifying the annotation at all replaces ArgoCD's default rather than
  adding to it (see "Update 2026-07-24" above for why `HookSucceeded` is
  deliberately left out).
- Image refs for the four published images are bare (no tag) in the
  manifests, since `argocd-image-updater` owns tag bumps via write-back.

---

## How to resume from just this file

If you're starting a fresh session with only this file (no conversation
history):

1. Read this file top to bottom — it has every decision and every exact
   name/value needed to cross-reference the manifests across all three repos.
2. Re-run the "Verification already done" commands to confirm nothing has
   drifted since this was written.
3. Check git status / `gh pr list` in `tch-umzh-connect-authentication-server`,
   `tch-umzh-connect-gitops`, and `tch-syseng-argocd-gitops` to see whether
   anything in "What's still outstanding" has since been pushed/merged/synced.
4. Pick up at whichever numbered item in "What's still outstanding" hasn't
   happened yet.
