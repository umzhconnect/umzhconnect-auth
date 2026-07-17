---
recap: "argocd-template/ is a minimal sample/template of the ArgoCD/kustomize manifests that run this repo's Keycloak realm — trimmed to just Keycloak, its runtime deps (Postgres, admin/pull secrets), and the Terraform configurator Job. Kept in this repo as a reusable reference; the real deployment lives in tch-umzh-connect-gitops."
keywords: [argocd-template, example-app, example-org, auth.example.com, example-vault, keycloak-config-job, tf-config, configMapGenerator, kustomization.yaml, postgresql.acid.zalan.do, ExternalSecret, regcred, keycloak-admin, PostSync hook, tf-workspace]
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

Validate the template still kustomize-builds after any edit:

```sh
cd argocd-template && kubectl kustomize . > /dev/null && echo OK
```
