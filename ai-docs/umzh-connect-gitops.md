---
recap: "Dev Kubernetes/ArgoCD deployment record spanning three repos — this repo builds images only, tch-umzh-connect-gitops holds all ArgoCD/k8s manifests, tch-syseng-argocd-gitops holds the Application CR. Covers the compose-to-k8s translation, why config crosses the repo boundary as baked images rather than ConfigMaps, and what's still outstanding."
keywords: [tch-umzh-connect-gitops, tch-syseng-argocd-gitops, argocd, kustomization.yaml, kgateway, Gateway, HTTPRoute, postgres-operator, postgresql.acid.zalan.do, umzh-connect namespace, auth.umzh.dev.example.com, tf-workspace, tf-config, ci-keycloak.yml, ci-token-validator.yml, ci-tf-config.yml, ci-jwks-server.yml, argocd-image-updater, deploy key, write-back]
---

# UMZH Connect Auth Server — dev k8s deployment

Status as of 2026-07-03. This doc is the resumable record of the dev
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
directly in this repo) — see "Why the gitops repo is separate" below for why,
and "History" at the bottom for the superseded approach.

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

This also fully retired the ConfigMap-based approach's `scopes.yaml` bug (see
History) — there's no `configMapGenerator` left to omit a file from.

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
- jwks-server Service: `jwks-server`, port `80` — matches what's already baked into `keycloak/config/hospitals/hospital-{a,b}.yaml` (`jwks_url: http://jwks-server/...`), confirmed by grep
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
- `argocd/kustomization.yaml` — new, lives inside `argocd/` (no more root-level workaround needed — see History), `images:` block lists all 4 images

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
grep -rn "jwks_url" keycloak/config/hospitals/

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

## History: superseded ConfigMap-based approach

The first version of this work put `argocd/*.yaml` + `kustomization.yaml`
directly in this repo, with a `configMapGenerator` reading `keycloak/terraform/*.tf`,
`keycloak/config/hospitals/*.yaml`, and `keys/*.jwks.json` straight from this
repo's working tree, copied onto the workspace PVC by an alpine initContainer.
That's been fully replaced by the image-baking approach above. Kept here only
because the reasoning explains some now-otherwise-mysterious details (e.g.
why the Job used to need an initContainer at all):

- **`kustomization.yaml` had to live at the repo root, not inside `argocd/`.**
  kustomize's `configMapGenerator` forbids file references that climb above
  its own directory via `../` (a security restriction ArgoCD's kustomize
  build also enforces), and the generators needed files from
  `keycloak/terraform/`, `keycloak/config/hospitals/`, and `keys/`, all
  siblings of `argocd/`. Verified this restriction is real (not just a style
  choice) by reproducing the exact `kubectl kustomize` failure when testing a
  move into `argocd/` — this is *why* a separate gitops repo needs a
  different config-delivery mechanism entirely, not just "move the same
  kustomization elsewhere". `--load-restrictor LoadRestrictionsNone` does fix
  it, but that flag is only settable cluster-wide (not per-Application) —
  rejected as out of scope and too broad a security-posture change for this
  one app.
- **A real bug was caught and fixed before the gitops-repo split happened:**
  `scopes.tf` reads `config/scopes.yaml`, but neither the `configMapGenerator`
  nor the initContainer's copy step ever sourced that file — only
  `tf-files`/`hospital-files` existed. The first real PostSync run would have
  failed before creating anything. This class of bug can no longer recur
  post-split, since there's no longer a manually-curated file list to miss an
  entry from — the `tf-config` image's `COPY keycloak/config /src/config`
  copies the whole directory.
- Other gotchas from that version (PostSync hook needing a fixed Job `name`,
  the `hook-delete-policy` needing `BeforeHookCreation,HookSucceeded` not just
  `HookSucceeded`, bare image refs with no tag for `argocd-image-updater`)
  still apply unchanged to the current manifests in `tch-umzh-connect-gitops`.

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
