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

| File | Purpose |
|---|---|
| `namespace.yaml` | Target namespace |
| `regcred.yaml` | `ExternalSecret` → image-pull secret for private registry images |
| `keycloak-admin-secret.yaml` | `ExternalSecret` → Keycloak bootstrap admin credentials |
| `database.yaml` | Postgres (Zalando `postgresql.acid.zalan.do` CR) that Keycloak's `KC_DB_*` env vars point at |
| `keycloak.yaml` | Keycloak `Deployment` + `Service` |
| `keycloak-config-job.yaml` | PostSync `Job` (+ PVC) that runs `terraform apply` against the running Keycloak to provision the realm |
| `keycloak_config/scopes.yaml` | Example client-scope config, read by Terraform |
| `keycloak_config/clients/example_client-l2.yaml` | Example per-client onboarding file, read by Terraform — mirrors `keycloak/config/clients/*.yaml` in the main repo |
| `kustomization.yaml` | Wires the above together, including the two `configMapGenerator`s the configurator job mounts |

Note the two config sources are deliberately different: Terraform's own
`.tf` files are baked into the `tf-config` image (`/src`), while the
client/scope YAML under `keycloak_config/` travels as two separate kustomize
`configMapGenerator`s — kept out of the image so onboarding a new client
doesn't require a rebuild. They're split in two (`example-app-scopes-config`
for `scopes.yaml`, `example-app-clients-config` for everything under
`clients/`) because `configMapGenerator` keys ConfigMap entries by basename
only and can't preserve a nested directory structure — mounting them as two
separate ConfigMap volumes in `keycloak-config-job.yaml`
(`.../config-source/scopes.yaml` + `.../config-source/clients/`) is what
reconstructs the `config/scopes.yaml` + `config/clients/*.yaml` split
Terraform expects. `configMapGenerator.files` also has no glob or
whole-directory form (verified against kustomize v5.8.1 — both a directory
path and a `*.yaml` glob fail with "must resolve to a file"), so each client
file must still be listed individually in `kustomization.yaml`.

## What's deliberately left out

- **jwks-server** — stands in for a real client's JWKS-publishing gateway;
  not needed to run Keycloak itself.
- **token-validator** — a mock resource server for testing issued tokens;
  not part of the auth server.
- **Gateway / HTTPRoute** — cluster-specific ingress (this project uses
  kgateway); swap in whatever your cluster's ingress convention is.

## Adapting this template

1. Replace every `example-org`/`example-app`/`auth.example.com`/
   `example-vault` placeholder with your own values.
2. Point `keycloak.yaml`'s image and `keycloak-config-job.yaml`'s
   `tf-config` image at your own built images (or build your own — see
   `tf-config/Dockerfile` in this repo for the pattern: bake your Terraform
   `.tf` files into an image so the gitops repo doesn't need read access
   to your source repo).
3. Add one file per client under `keycloak_config/clients/` for each client
   you want to onboard, named after its own `client_id`
   (`{name}-{l1|l2}.yaml`, e.g. `hospital_a-l2.yaml`) — there is no implicit
   access, a client with no file has no KC client and cannot obtain tokens.
   Also add its path to the `example-app-clients-config` generator's
   `files` list in `kustomization.yaml` — kustomize can't glob or list a
   whole directory here, so this second edit can't be avoided.
4. Verify with `kubectl kustomize .` before committing to a gitops repo.
