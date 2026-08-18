---
recap: "argocd-template/ is a minimal sample/template of the ArgoCD/kustomize manifests that run this repo's Keycloak realm — trimmed to just Keycloak, its runtime deps (Postgres, admin/pull secrets), and a two-image (tf-config + configurator) Terraform job. Kept in this repo as a reusable reference; the real deployment lives in tch-umzh-connect-gitops."
keywords: [argocd-template, example-app, example-org, auth.example.com, example-vault, keycloak-config-job, tf-config, configurator, configurator/Dockerfile, kustomization.yaml, postgresql.acid.zalan.do, ExternalSecret, regcred, keycloak-admin, PostSync hook, hook-delete-policy, tf-workspace, keycloak-config/clients, example_client-l1, allow_l1_debug_clients, example-app-configurator]
---

# ArgoCD template (example)

`argocd-template/` at the repo root is a standalone, sample kustomize
directory demonstrating the minimal ArgoCD manifest set needed to run
Keycloak + a Terraform-driven realm configurator on Kubernetes. It is **not**
used by any pipeline or ArgoCD `Application` — it's a reference/starting
point, kept separate from the real dev deployment.

Layout: `argocd/` holds the manifests + `kustomization.yaml`;
`keycloak-config/` (top-level, sibling of `argocd/`) holds the example
scope/client YAML; `configurator/Dockerfile` bakes `keycloak-config/` into an
image. This mirrors `tch-umzh-connect-gitops`'s own top-level layout
(`argocd/`, `keycloak-config/`, `configurator/`).

See [`argocd-template/README.md`](../argocd-template/README.md) for the file
list, what's intentionally omitted (jwks-server, token-validator, ingress),
and how to adapt the placeholders for real use.

For the actual dev deployment (which this template was
derived from), see [ai-docs/umzh-connect-gitops.md](umzh-connect-gitops.md)
and [ai-docs/infrastructure.md](infrastructure.md) — those describe the real
manifests living in the separate `tch-umzh-connect-gitops` repo.

## Config is baked into a second image

`keycloak-config-job.yaml` runs a single `configurator` image directly. Two
Dockerfiles chain together:

1. Your own `tf-config` image (see this repo's `tf-config/Dockerfile` for the
   pattern: `FROM hashicorp/terraform:<pin>`, `COPY <your terraform> /src/terraform`,
   `COPY <your own keycloak-config/> /src/keycloak-config`).
2. `configurator/Dockerfile` here: `FROM <your tf-config image>`,
   `COPY keycloak-config/. /src/keycloak-config` — this overwrites `/src/keycloak-config` from
   step 1 with this deployment's own client/scope files.

The Job's script is just:

```sh
mkdir -p /workspace/terraform /workspace/keycloak-config
cp -rf /src/terraform/. /workspace/terraform/
cp -rf /src/keycloak-config/. /workspace/keycloak-config/
terraform init -input=false
terraform apply -auto-approve -input=false
```

copying both onto the `tf-workspace` PVC so `terraform.tfstate` survives Job
re-runs even though the images themselves are immutable per tag.

Onboarding a new client is therefore one step: add a file under
`keycloak-config/clients/`, rebuild/push the `configurator` image. There's no
second `kustomization.yaml` edit to remember — a single point of edit for
config changes.

## L1 debug client example

`keycloak-config/clients/example_client-l1.yaml` demonstrates the
[ADR 0004](../docs/adr/0004-reinstate-l1-debug-client.md) opt-in pattern: an
`auth_level: "L1"` file alone is not enough — `keycloak-config-job.yaml`'s
`TF_VAR_allow_l1_debug_clients` env var defaults to `"false"` so copying this
template can't silently enable L1 debug clients; flip it to `"true"`
per-deployment for `example_client-l1.yaml` to actually be provisioned.

## `hook-delete-policy` omits `HookSucceeded`

`argocd.argoproj.io/hook-delete-policy: BeforeHookCreation` (not also
`HookSucceeded`) is deliberate: including `HookSucceeded` would delete the
Job (and its pod logs) the instant it succeeds, leaving nothing to inspect
after a sync. `BeforeHookCreation` alone still guarantees the next sync's
identical-spec Job creation isn't a no-op against a leftover Job.

## Validate after any edit

```sh
cd argocd-template && kubectl kustomize argocd/ > /dev/null && echo OK
```
