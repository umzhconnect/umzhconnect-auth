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
| `keycloak_config/example-client.yaml` | Example per-client onboarding file, read by Terraform |
| `kustomization.yaml` | Wires the above together, including the `configMapGenerator` the configurator job mounts |

Note the two config sources are deliberately different: Terraform's own
`.tf` files are baked into the `tf-config` image (`/src`), while the
client/scope YAML under `keycloak_config/` travels as a kustomize
`configMapGenerator` mounted flat at `/config` — kept out of the image so
onboarding a new client doesn't require a rebuild. `configMapGenerator` keys
ConfigMap entries by basename only, so files here can't live in
subdirectories (e.g. no `clients/` folder) — see the comment in
`example-client.yaml`.

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
3. Add one file per client under `keycloak_config/` for each client you
   want to onboard — there is no implicit access, a client with no file has
   no KC client and cannot obtain tokens. Also add it to `kustomization.yaml`'s
   `configMapGenerator.files` list.
4. Verify with `kubectl kustomize .` before committing to a gitops repo.
