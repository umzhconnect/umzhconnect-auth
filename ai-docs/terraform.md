---
recap: "Terraform structure and pitfalls — YAML-driven client generation, audiences.tf, the extra_config double-nesting trap, and apply commands."
keywords: [keycloak/keycloak ~>5.0, extra_config, attributes prefix, double-nesting, jwks.url, use.jwks.url, audiences.tf, clients.tf, scopes.tf, fhir-servers.yaml, yamldecode, local.fhir_servers, include_in_token_scope, TF_VAR_keycloak_url, keycloak-config, apply command, KC client naming, for_each, default_scopes]
---

# Terraform

Provider: `keycloak/keycloak ~> 5.0` (`keycloak/terraform/versions.tf`).

## File structure

| File | Responsibility |
|------|----------------|
| `audiences.tf` | Reads `fhir-servers.yaml` → one `aud:<key>` client scope + audience mapper per FHIR server |
| `clients.tf` | Reads `config/apps/` + `config/grants/` → KC clients + mappers + default scopes |
| `scopes.tf` | SMART system scope vocabulary — stable, stays HCL |
| `realm.tf` | Realm-level settings |
| `variables.tf` | Input variables |

## audiences.tf — how it works

Reads `fhir-servers.yaml` via `yamldecode`. Creates one `keycloak_openid_client_scope` named `aud:<key>` per server with `include_in_token_scope = false` (suppresses the scope name from the `scope` claim — the audience mapper fires independently). Each scope has an audience mapper that sets `aud` = the FHIR server URL.

```hcl
locals {
  fhir_servers = yamldecode(file("${path.module}/../config/fhir-servers.yaml")).servers
}

resource "keycloak_openid_client_scope" "aud" {
  for_each               = local.fhir_servers
  realm_id               = keycloak_realm.umzh_connect.id
  name                   = "aud:${each.key}"
  include_in_token_scope = false
}
```

## clients.tf — how it works

Loads all app files from `config/apps/` and all grant files from `config/grants/`. Flattens grant entries into a map keyed by KC client ID (`{org_id}--{app_id}--{server_key}`). For each entry creates a `keycloak_openid_client` with:
- `client-jwt` authenticator, `jwks_url` from the app file
- Default scopes = granted SMART scopes + `aud:<server_key>`
- No optional scopes
- Mappers: `org-reference-mapper`, `fhir-context-mapper`, `tenant-mapper`, `realm-roles`

## The `extra_config` trap — no `attributes.` prefix

`extra_config` on `keycloak_openid_client` maps directly into Keycloak's `attributes` object. **Do not add an `attributes.` prefix to key names** — they will be double-nested (`attributes.attributes.foo`) and silently ignored by Keycloak.

Correct:
```hcl
extra_config = {
  "use.jwks.url" = "true"
  "jwks.url"     = each.value.jwks_url   # sourced from config/apps/{org}--{app}.yaml
}
```

Wrong (silently broken):
```hcl
extra_config = {
  "attributes.jwks.url" = "true"   # double-nested, ignored
}
```

## Apply commands

Re-apply after any config change:

```sh
# Direct (outside compose network)
TF_VAR_keycloak_url=http://localhost:8180 \
  terraform -chdir=keycloak/terraform apply -auto-approve

# Via compose (uses compose network, keycloak:8080 backchannel URL)
docker compose up keycloak-config
```
