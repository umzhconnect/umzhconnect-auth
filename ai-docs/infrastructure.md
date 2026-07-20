---
recap: "docker-compose stack — services, the KC_HOSTNAME_BACKCHANNEL_DYNAMIC split between internal and published URLs, and the jwks-server role. Also covers the dev k8s deployment: manifests live in the separate tch-umzh-connect-gitops repo, this repo only builds the images (keycloak, token-validator, tf-config, jwks-server) they reference."
keywords: [KC_HOSTNAME_BACKCHANNEL_DYNAMIC, keycloak:8080, localhost:8180, backchannel URL, published issuer, jwks-server, nginx, token-validator, keycloak-config, start-dev, production hardening, TF_VAR_keycloak_url, apisix, compose network, tch-umzh-connect-gitops, kgateway, Gateway, HTTPRoute, postgres-operator, postgresql.acid.zalan.do, umzh-connect namespace, auth.umzh.dev.example.com, tf-workspace, tf-config, ci-keycloak.yml, ci-token-validator.yml, ci-tf-config.yml, ci-jwks-server.yml, argocd-image-updater, allow_l1_debug_clients, TF_VAR_allow_l1_debug_clients, hospitals-l1, ADR 0004]
---

# Infrastructure

## Services

| Service | URL (host) | Notes |
|---------|-----------|-------|
| `keycloak` | http://localhost:8180 | admin / admin; issuer `http://localhost:8180/realms/umzh-connect` |
| `keycloak-config` | — | One-shot Terraform apply; runs and exits |
| `jwks-server` | http://localhost:8085 | nginx serving demo L2 client JWKS files from `keys/` |
| `token-validator` | http://localhost:8086 | Mock resource server |

## KC_HOSTNAME_BACKCHANNEL_DYNAMIC

`KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` in `docker-compose.yml` lets in-network services (Terraform, token-validator) reach Keycloak at `http://keycloak:8080` while the published issuer remains `http://localhost:8180/realms/umzh-connect`.

This is why:
- `TF_VAR_keycloak_url` inside compose uses `http://keycloak:8080` (the backchannel address).
- Tokens still show `http://localhost:8180/realms/umzh-connect` in the `iss` claim.

When running Terraform directly on the host (outside compose): `TF_VAR_keycloak_url=http://localhost:8180`.

## jwks-server

Stands in for the sandbox's APISIX gateways, which publish client JWKS at `/jwks.json` on each party's external gateway. For drop-in sandbox use, override the Terraform variables:

```sh
TF_VAR_placer_l2_jwks_url=http://apisix-placer-external:9080/jwks.json \
TF_VAR_fulfiller_l2_jwks_url=http://apisix-fulfiller-external:9080/jwks.json \
terraform apply
```

## Dev-only flags

`start-dev` in `docker-compose.yml` disables all Keycloak production hardening. Always document this clearly and never use it in a production image. For production, the command becomes `start --optimized`.

## Enabling L1 debug clients locally

`allow_l1_debug_clients` (`keycloak/terraform/variables.tf`, default `false`) gates whether `config/hospitals-l1/*.yaml` files are actually provisioned — see [terraform.md](terraform.md) and [ADR 0004](../docs/adr/0004-reinstate-l1-debug-client.md). By default `docker compose up keycloak-config` **ignores** any file under `config/hospitals-l1/` (e.g. the `hospital-a.yaml` example) and only logs a warning; it does not create the L1 client.

`docker-compose.yml`'s `keycloak-config` service now forwards this through explicitly:

```yaml
environment:
  TF_VAR_allow_l1_debug_clients: ${TF_VAR_allow_l1_debug_clients:-false}
```

This is required — **Compose does not pass arbitrary host environment variables into a container**, only ones the service explicitly lists (directly or via `${...}` substitution, as above). Exporting `TF_VAR_allow_l1_debug_clients=true` in your shell and running `docker compose up keycloak-config` with an *older* compose file that didn't reference the var at all had no effect on the container, regardless of the shell export — this is what silently produced the ignored-with-a-warning outcome.

To enable L1 clients for local testing, with the `environment:` entry above in place:

```sh
TF_VAR_allow_l1_debug_clients=true docker compose up keycloak-config
```

**Watch for the "up-to-date, skipping" trap too.** `docker compose up <service>` only recreates a container when Compose detects its resolved config changed since the last run. If you've already run `keycloak-config` once (e.g. as part of `docker compose up` for the whole stack) and then re-run `docker compose up keycloak-config` with a *different* value for `TF_VAR_allow_l1_debug_clients`, Compose does detect the changed resolved environment and recreates it — but if you're unsure, or want a guaranteed one-off apply without touching the persistent container's state, use `run` instead of `up`:

```sh
docker compose run --rm -e TF_VAR_allow_l1_debug_clients=true keycloak-config
```

`run` always starts a fresh container with the given `-e` override, sidestepping the "already up to date" check entirely.

Either way, this is a local convenience only — do not commit a non-`false` default for `TF_VAR_allow_l1_debug_clients` in `docker-compose.yml`, and don't carry the override into any shared/prod compose or gitops manifest; see the "Safeguard" note in [terraform.md](terraform.md).

After enabling, fetch the generated secret with `terraform output -json m2m_l1_client_secrets` (from `keycloak/terraform/`, or `docker compose exec keycloak-config terraform output ...` if run inside the container) to use with `bruno/auth/09-get-placer-token-l1.bru`.

## Dev k8s deployment (ArgoCD)

All ArgoCD/k8s manifests live in the separate **`tch-umzh-connect-gitops`** repo
(`argocd/*.yaml` + `argocd/kustomization.yaml` there), not in this repo. This
repo only owns image building (Dockerfiles + CI) and the Terraform/config
source files those images package. The ArgoCD `Application` is defined at
`tch-syseng-argocd-gitops/argocd/overlays/dev/applications/umzh-connect-auth.yaml`
and points `spec.source` at `tch-umzh-connect-gitops` (`path: argocd`).

This split means the gitops repo cannot read this repo's raw files (no shared
checkout, and ArgoCD's multi-source `$ref` substitution only works for Helm
`valueFiles`, not kustomize `configMapGenerator`) — so anything the k8s
manifests used to pull in as a `configMapGenerator` file is instead **baked
into an image** by this repo and referenced by tag, same as `keycloak`/
`token-validator` already were:

| compose service | k8s equivalent | image built here | manifest (in `tch-umzh-connect-gitops`) |
|---|---|---|---|
| `postgres` | `postgresql.acid.zalan.do` CR (Zalando postgres-operator, already in the dev cluster), 5Gi PVC. Operator auto-creates a credentials Secret `keycloak.umzh-connect-db.credentials.postgresql.acid.zalan.do` | — | `argocd/database.yaml` |
| `keycloak` | Deployment + Service, still `start-dev` | `keycloak/Dockerfile` | `argocd/keycloak.yaml` |
| `keycloak-config` | k8s `Job`, ArgoCD `PostSync` hook. Runs `terraform apply` using the `.tf` files and hospital/scope config baked into the `tf-config` image at `/src`; the container copies them onto a persistent workspace (`tf-workspace` PVC) before applying, so `terraform.tfstate` survives across hook re-runs — otherwise every sync would try to recreate an already-existing realm | `tf-config/Dockerfile` (`FROM hashicorp/terraform:1.9`, `COPY keycloak/terraform`, `COPY keycloak/config`) | `argocd/keycloak-config-job.yaml` |
| `jwks-server` | Deployment + Service serving only the public `*.jwks.json` files — the image bakes in just those two files, so the "never serve the demo private `.key` files over HTTP" rule is enforced at build time instead of a manually curated ConfigMap file list | `jwks-server/Dockerfile` (`FROM nginx:1.27-alpine`, `COPY keys/*.jwks.json`) | `argocd/jwks-server.yaml` |
| `token-validator` | Deployment + Service | `token-validator/Dockerfile` | `argocd/token-validator.yaml` |

**Routing:** the dev cluster's convention for new apps is **kgateway** (Gateway API), not nginx `Ingress` — `argocd/gateway.yaml` (a `Gateway`, `gatewayClassName: kgateway`) and `argocd/httproute.yaml` (an `HTTPRoute` + a paired https-redirect route) publish Keycloak at `https://auth.umzh.dev.example.com`, matching `KC_HOSTNAME`. Internal callers (the Terraform job, token-validator) still use the in-cluster Service DNS (`keycloak:8080`) for the backchannel — same split as `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` in compose, just with a real hostname instead of `localhost:8180`.

**Images (all built here, all bespoke CI, none use `containerized.yml`):** `.github/workflows/ci-keycloak.yml`, `ci-token-validator.yml`, `ci-tf-config.yml`, `ci-jwks-server.yml` — bespoke `docker/build-push-action` jobs because `containerized.yml` hardcodes the GHCR image name to `ghcr.io/<owner>/<repo>` with no per-image override (this repo publishes four distinct images) and skips publish on `main`/`master` without an explicit tag input. All four support `workflow_dispatch` so any image can be rebuilt/pushed on demand. `tf-config` and `jwks-server` have no application source code to scan, so they're not part of `sast.yml`. `argocd-image-updater` (configured on the `Application` in `tch-syseng-argocd-gitops`) tracks all four and rewrites `tch-umzh-connect-gitops/argocd/kustomization.yaml`'s `images:` block on new pushes — that repo needs its own write-capable deploy key, separate from (and not reusing) any read-only key this repo might have.
