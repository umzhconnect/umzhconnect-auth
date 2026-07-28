# Deploying realm config to Keycloak: approaches considered

This document tracks how the Terraform realm config (`keycloak/terraform/`,
`keycloak/config/`) gets from this repo into a running cluster deployment,
why the current approach was chosen, and what alternatives exist if the
two-image approach turns out to be too much operational overhead.

It's written generically — in terms of "the config repo" / "the gitops
repo" / "an object store" — so it applies to any adopter of this template,
not just this project's own dev deployment. For this project's concrete
repo names and exact values, see
[ai-docs/umzh-connect-gitops.md](../ai-docs/umzh-connect-gitops.md) (internal
doc, not part of the reusable template).

---

## 1. Previous approach: `configMapGenerator`

Kustomize's `configMapGenerator` read the raw `.tf` / client YAML files
directly off disk at kustomize-build time and generated a `ConfigMap`,
mounted as a volume into the Terraform `Job`.

**How it worked:** the gitops repo needed its own copy of the raw config
files (kustomize has no cross-repo file reference — `configMapGenerator`
only reads local paths), so files were duplicated/synced into the gitops
repo's tree, and `kustomization.yaml` listed them individually under
`configMapGenerator.files`.

**Why it was dropped:**

- **Scaling limit.** A `ConfigMap`'s total serialized size is capped by
  etcd's ~1MiB per-object value limit. Each hospital's client YAML is small,
  but the limit is shared across the whole realm's `.tf` files, scope
  definitions, and every onboarded client — it does not scale indefinitely
  as more hospitals are onboarded.
- **Manual file sync.** Every config change had to be copied into the
  gitops repo's tree by hand (or by a sync script) and listed explicitly in
  `kustomization.yaml` — a second point of edit to remember, and a place
  a file could be silently omitted from the generator's file list.
- **No natural versioning/audit trail.** A `ConfigMap` is just current
  state; there's no built-in way to see "what did this hospital's config
  look like three deploys ago" without digging through the gitops repo's
  git history for that specific file.

## 2. Current approach: layered Docker images

Terraform's own `.tf` files are baked into a `tf-config` image
(`FROM hashicorp/terraform:<pin>`, `COPY terraform/ /src/terraform`,
`COPY config/ /src/config`). A second `configurator` image layers on top
(`FROM <tf-config image>`, `COPY keycloak-config/. /src/config`),
overwriting `/src/config` with the deployment's own client/scope files. The
`configurator` image is what the ArgoCD `PostSync` `Job` actually runs: it
copies `/src/terraform` and `/src/config` onto a persistent `tf-workspace`
PVC (so `terraform.tfstate` survives Job re-runs) and runs
`terraform apply`.

**Why it was chosen:**

- No `ConfigMap`/etcd size ceiling — config size is bounded only by image
  storage, which scales indefinitely.
- Every file is `COPY`'d wholesale, so there's no curated file list that can
  silently omit a file — onboarding a client is "add a file, rebuild the
  image."
- The resulting image is an immutable, versioned, content-addressable
  artifact (tag/digest) — trivially reproducible and rollback-able.

**Trade-off:** onboarding or changing a single hospital's client config
now requires building and pushing a full container image (via CI), even though
the actual change is a few lines of YAML. Two images in the chain
(`tf-config` → `configurator`) means two build steps and two things that
can go stale relative to each other.

---

## Additional options to consider

### 3. Config on a mounted volume (cloud object storage)

Store `keycloak-config/` (and optionally `terraform/`) in an Azure Storage
Account container or an S3-compatible bucket, and mount it into the
Terraform `Job` at runtime instead of baking it into an image — e.g. via
the Azure Blob CSI driver / `azurefile-csi`, the S3 CSI driver
(`mountpoint-s3`), or an `initContainer` that runs
`az storage blob download-batch` / `aws s3 sync` into an `emptyDir` before
the main container starts.

**Pros:**
- Onboarding a client becomes "upload/update a file in the bucket" — no
  image build, no CI, no image registry involved at all for config changes.
- Config changes take effect on the next Job run without needing a new
  image tag or an ArgoCD sync triggered by a manifest change.
- Decouples config lifecycle entirely from the image lifecycle (Keycloak
  itself, `tf-config`'s Terraform modules) — those still get rebuilt only
  when the code actually changes.

**Cons:**
- Introduces a new dependency: a CSI driver (or cloud CLI + credentials)
  must be available and configured in every cluster that runs this
  deployment — not just "any Kubernetes cluster with ArgoCD."
- No natural versioning/rollback unless the bucket itself has versioning
  enabled and something is disciplined about reading a specific version, not
  just "latest."
- Config changes no longer go through a PR/review process by default —
  anyone with bucket write access can change what gets applied, with no git
  history unless a separate process enforces "bucket writes only via CI."
- Access control shifts to cloud IAM/SAS tokens instead of git repo
  permissions — a different (and for many teams, less familiar) place to
  manage who can change a hospital's client config.

### 4. Config repo cloned at Job runtime (no image involved)

Keep client/scope YAML in a git repo (could be the gitops repo itself, or a
dedicated config-only repo), and have the Terraform `Job` clone it directly
via an `initContainer` (e.g. `alpine/git clone`) into an `emptyDir`, instead
of it being baked into any image. Only `tf-config` (the Terraform modules
themselves) stays image-based, since those change far less often than
per-hospital config.

**Pros:**
- Onboarding a client is a plain `git push` — no build step, no registry,
  no CI pipeline at all if the Job always clones the branch's HEAD.
- Config keeps full git history, PR review, and `git blame` for free — no
  separate versioning story to design, unlike the object-storage option.
- Much smaller change surface than the current two-image chain: only one
  image (`tf-config`) remains, and it changes only when Terraform code
  changes.

**Cons:**
- The Job needs git read credentials (a deploy key or PAT) mounted as a
  secret, and network egress from the cluster to the git host — a new
  runtime dependency that baked images don't have.
- Less reproducible than an image tag: cloning "HEAD of branch X" at Job
  run time means the exact config applied depends on *when* the Job ran,
  not a single pinned, content-addressable reference — unless the Job is
  parameterized to clone a specific commit SHA (which then reintroduces a
  "bump a value somewhere" step, just a lighter one than a rebuild).
- `terraform apply` runs against whatever the clone produced; if the git
  host is briefly unreachable, the PostSync hook fails outright rather than
  reusing a previously-pulled image.

### 5. Full CI/CD sync-and-apply (config never touches the cluster via ArgoCD)

Move config delivery out of ArgoCD/Kubernetes entirely: a CI pipeline
(triggered on merge to the config repo) runs `terraform apply` directly
against the target Keycloak instance from the CI runner (or from a
short-lived Job it creates via `kubectl apply --wait` outside of ArgoCD's
own sync), using cluster/Keycloak credentials scoped to CI.

**Pros:**
- Fastest feedback loop for a hospital onboarding change: merge the PR, CI
  applies it, done — no image build, no waiting for the next ArgoCD sync.
- Reuses whatever CI/CD tooling and approval gates (required reviewers,
  environments) the org already has for other deployments.

**Cons:**
- Breaks GitOps's core guarantee: the cluster's actual state can now
  diverge from what ArgoCD believes is the source of truth, since a change
  was applied outside its sync cycle. Reconciling "what's actually running"
  requires checking two systems (ArgoCD *and* the CI pipeline's apply
  history) instead of one.
- The `PostSync` hook's ordering guarantee (Keycloak must be up before
  Terraform runs against it) has to be re-implemented as a CI-side check
  instead of something ArgoCD/Kubernetes already guarantees.
- CI needs direct, standing credentials to reach the cluster/Keycloak
  instance — a broader blast radius than "CI can push images to a
  registry," which is all it needs today.

---

## Summary comparison

| Approach | Config change requires | New infra dependency | Versioning/audit | GitOps purity |
|---|---|---|---|---|
| `configMapGenerator` (previous) | Manual file sync + kustomize edit | None | Weak (ConfigMap is just current state) | Full |
| Layered images (current) | CI build + push of an image | None (uses existing registry) | Strong (image tag/digest) | Full |
| Object storage volume | Upload to bucket | CSI driver or cloud CLI + IAM | Weak, unless bucket versioning is used deliberately | Full (Job still runs via ArgoCD hook) |
| Git clone at Job runtime | `git push` | Git credentials + egress from Job | Strong (git history), but not pinned unless SHA-parameterized | Full |
| CI/CD apply (bypasses ArgoCD) | `git push` + CI apply | Standing CI→cluster credentials | Strong (git + CI logs), but split across two systems | Broken — cluster can drift from ArgoCD's view |

No option is proposed as a replacement here — this is a reference for
weighing "how much process per config change" against "how much new
infrastructure/credential surface" when discussing this with USZ, Balgrist,
or future adopters of this template.
