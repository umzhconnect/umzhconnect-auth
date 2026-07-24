---
recap: "argocd-template/ is a minimal sample/template of the ArgoCD/kustomize manifests that run this repo's Keycloak realm — trimmed to just Keycloak, its runtime deps (Postgres, admin/pull secrets), and the Terraform configurator Job. Kept in this repo as a reusable reference; the real deployment lives in tch-umzh-connect-gitops."
keywords: [argocd-template, example-app, example-org, auth.example.com, example-vault, keycloak-config-job, tf-config, configMapGenerator, kustomization.yaml, postgresql.acid.zalan.do, ExternalSecret, regcred, keycloak-admin, PostSync hook, tf-workspace, keycloak_config/clients, example-app-scopes-config, example-app-clients-config, config-source]
---

# ArgoCD template (example)

`argocd-template/` at the repo root is a standalone, sample kustomize
directory demonstrating the minimal ArgoCD manifest set needed to run
Keycloak + a Terraform-driven realm configurator on Kubernetes. It is **not**
used by any pipeline or ArgoCD `Application` — it's a reference/starting
point, kept separate from the real dev deployment.

See [`argocd-template/README.md`](../argocd-template/README.md) for the file
list, what's intentionally omitted (jwks-server, token-validator, ingress),
and how to adapt the placeholders for real use.

For the actual dev deployment (which this template was
derived from), see [ai-docs/umzh-connect-gitops.md](umzh-connect-gitops.md)
and [ai-docs/infrastructure.md](infrastructure.md) — those describe the real
manifests living in the separate `tch-umzh-connect-gitops` repo.

`keycloak-config-job.yaml` mounts two separate `configMapGenerator`-built
ConfigMaps — `example-app-scopes-config` (from `keycloak_config/scopes.yaml`)
and `example-app-clients-config` (from `keycloak_config/clients/*.yaml`) —
rather than one, because `configMapGenerator` keys every entry by basename
only and can't preserve the `clients/` nesting Terraform expects
(`config/scopes.yaml` + `config/clients/*.yaml`, mirroring
`keycloak/config/` in the main repo). They land at
`/config-source/scopes.yaml` (via a `subPath` mount of the single key) and
`/config-source/clients/` respectively, and the Job's script copies both
onto the `tf-workspace` PVC before running Terraform.

`configMapGenerator.files` has no glob or whole-directory form — verified
against kustomize v5.8.1: both a bare directory path and a `*.yaml` glob
fail with `"must resolve to a file"`. So onboarding a new client still means
two edits: add the YAML under `keycloak_config/clients/`, and add its path
to the `example-app-clients-config` generator's `files` list in
`kustomization.yaml`.

The clients copy step uses `cp -rfL` — the `-L` is required, not cosmetic.
Kubernetes projects each (non-`subPath`) ConfigMap key as a symlink
(`example_client-l2.yaml -> ..data/example_client-l2.yaml`); the
`hashicorp/terraform` image is Alpine/busybox-based, and busybox `cp`
copies symlinks as symlinks by default (unlike GNU coreutils `cp`, which
dereferences top-level symlink arguments). Without `-L`, the copied symlink
is dangling in its new directory (no `../data/` there) and Terraform's
`file()` call fails with "no file exists at ../config/clients/..." even
though the ConfigMap and source YAML are both correct. The `scopes.yaml`
mount uses `subPath` instead, which Kubernetes materializes as a direct
file rather than a symlink, so its copy doesn't need `-L` to work — it's
kept for consistency with the clients copy, not because it's required
there.

Validate the template still kustomize-builds after any edit:

```sh
cd argocd-template && kubectl kustomize . > /dev/null && echo OK
```
