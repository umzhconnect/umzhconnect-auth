# ArgoCD template — Keycloak + configurator (example)

A minimal sample of the ArgoCD/kustomize manifests used to run
this repo's Keycloak realm on Kubernetes. It's a trimmed-down copy of what
actually runs in the separate `tch-umzh-connect-gitops` repo (see
[`ai-docs/umzh-connect-gitops.md`](../ai-docs/umzh-connect-gitops.md) for the
real deployment) — kept here as a reusable reference for
standing up Keycloak + a Terraform-driven realm config elsewhere.

All names (`example-app`, `example-org`, `auth.example.com`, `example-vault`,
etc.) are placeholders. Swap them for your own namespace, registry, hostname,
and secrets-store before using this anywhere real.

## What's included

Only the Keycloak server, its direct runtime dependencies, and the
configurator job — the smallest set needed to get a working realm:

| Path | Purpose |
|---|---|
| `argocd/namespace.yaml` | Target namespace |
| `argocd/regcred.yaml` | `ExternalSecret` → image-pull secret for private registry images |
| `argocd/keycloak-admin-secret.yaml` | `ExternalSecret` → Keycloak bootstrap admin credentials |
| `argocd/database.yaml` | Postgres (Zalando `postgresql.acid.zalan.do` CR) that Keycloak's `KC_DB_*` env vars point at |
| `argocd/keycloak.yaml` | Keycloak `Deployment` + `Service` |
| `argocd/keycloak-config-job.yaml` | PostSync `Job` (+ PVC) that runs `terraform apply` against the running Keycloak to provision the realm |
| `argocd/kustomization.yaml` | Wires the above together |
| `keycloak-config/scopes.yaml` | Example client-scope config, read by Terraform |
| `keycloak-config/clients/example_client-l2.yaml` | Example per-client onboarding file (L2/`private_key_jwt`), read by Terraform — mirrors `keycloak-config/clients/*.yaml` in the main repo |
| `keycloak-config/clients/example_client-l1.yaml` | Example L1 (`client_secret`) debug client, demonstrating the ADR 0004 opt-in pattern |
| `configurator/Dockerfile` | Layers `keycloak-config/` on top of your `tf-config` image, so the Job needs no ConfigMap |

Note the two config sources are deliberately different: Terraform's own
`.tf` files are baked into your `tf-config` image (`/src/terraform`, via
your own `tf-config/Dockerfile` — see this repo's for the pattern), while
`keycloak-config/` (client/scope YAML) is baked into a second,
`configurator` image built from `configurator/Dockerfile`
(`FROM <your tf-config image>`, `COPY keycloak-config/. /src/keycloak-config`) that
layers on top of it and overwrites `/src/keycloak-config`. `keycloak-config-job.yaml`
runs that `configurator` image directly — both `/src/terraform` and
`/src/keycloak-config` are already present, so there's no ConfigMap, no kustomize
`configMapGenerator`, and no second edit anywhere to remember when
onboarding a client. This also means deployment-specific clients (e.g. a
throwaway test client for one environment only) don't need to touch your
source repo's own config at all — they just live in `keycloak-config/` in
whatever repo builds the `configurator` image.

Terraform state must still survive Job re-runs (otherwise every sync would
try to re-create an already-existing realm), so the Job copies both
`/src/terraform` and `/src/keycloak-config` onto a persistent `tf-workspace` PVC on
every start, and only the resulting `terraform.tfstate` is kept across runs.

## What's deliberately left out

- **jwks-server** — stands in for a real client's JWKS-publishing gateway;
  not needed to run Keycloak itself.
- **token-validator** — a mock resource server for testing issued tokens;
  not part of the auth server.
- **Gateway / HTTPRoute / traffic policies** — cluster-specific ingress
  (this project uses kgateway); swap in whatever your cluster's ingress
  convention is.

## Adapting this template

1. Replace every `example-org`/`example-app`/`auth.example.com`/
   `example-vault` placeholder with your own values.
2. Point `argocd/keycloak.yaml`'s image and
   `argocd/keycloak-config-job.yaml`'s image at your own built images (or
   build your own — see `tf-config/Dockerfile` in this repo for the
   `tf-config` pattern, and `configurator/Dockerfile` here for how it layers
   on top).
3. Add one file per client under `keycloak-config/clients/` for each client
   you want to onboard, named after its own `client_id`
   (`{name}-{l1|l2}.yaml`, e.g. `hospital_a-l2.yaml`) — there is no implicit
   access, a client with no file has no KC client and cannot obtain tokens.
   Rebuild and push the `configurator` image; no kustomize edit is needed.
4. L1 (`client_secret`) clients are an explicit, narrow opt-in (see
   [ADR 0004](../docs/adr/0004-reinstate-l1-debug-client.md)) — an L1 file
   alone isn't provisioned unless `TF_VAR_allow_l1_debug_clients=true` is
   also set on the Job (see `argocd/keycloak-config-job.yaml`). Leave it
   `false`/unset to have Terraform ignore L1 files with a warning.
5. Verify with `kubectl kustomize argocd/` before committing to a gitops
   repo.
