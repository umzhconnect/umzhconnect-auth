---
recap: "Terraform structure and pitfalls — hospital YAML-driven client generation, D2 aud: scopes, extra_config double-nesting trap, Vault secrets, and apply commands."
keywords: [keycloak/keycloak ~>5.0, extra_config, attributes prefix, double-nesting, jwks.url, use.jwks.url, clients.tf, scopes.tf, realm.tf, yamldecode, local.hospitals, TF_VAR_keycloak_url, keycloak-config, apply command, for_each, config/hospitals, org_id, org_display_name, org_reference, jwks_url, vault, vault_kv_secret_v2, admin_password, JWT OIDC, org-reference-mapper, fhir-context-mapper, aud_scope, aud_scope_mapper, keycloak_openid_client_scope, include_in_token_scope, included_custom_audience, allowed_targets, D2, ADR 0005]
---

# Terraform

Provider: `keycloak/keycloak ~> 5.0` (`keycloak/terraform/versions.tf`).

## File structure

| File | Responsibility |
|------|----------------|
| `clients.tf` | Reads `config/hospitals/*.yaml` → one L2 KC client per hospital + protocol mappers |
| `realm.tf` | Realm-level settings |
| `variables.tf` | Input variables |
| `outputs.tf` | Outputs (client IDs, etc.) |
| `versions.tf` | Provider version pins |

## clients.tf — how it works

Reads all `*.yaml` files from `config/hospitals/`. Each file defines one hospital. Creates:
- One `keycloak_openid_client` per hospital with `client-jwt` authenticator and the hospital's `jwks_url`
- `org-reference-mapper` — hardcoded claim mapper setting `extensions.umzhconnect.organization_reference`
- `fhir-context-mapper` — custom protocol mapper for `authorization_details` → `fhirContext`
- `aud:{org_id}` realm-level client scope with an audience mapper writing `fhir_url` into `aud`

KC client ID = `{org_id}` (the YAML filename without `.yaml`).

Hospital YAML schema (`config/hospitals/{org_id}.yaml`):

```yaml
org_id: "hospital-a"
org_display_name: "Hospital A"
org_reference: "https://fhir.hospital-a.example/fhir/Organization/HospitalA"
fhir_url: "https://fhir.hospital-a.example/fhir"
jwks_url: "https://hospital-a.example/.well-known/jwks.json"
allowed_targets:
  - "hospital-b"
```

`allowed_targets` drives which `aud:` scopes are assigned as optional on this client's M2M profile (see `scopes.tf`). Adding a hospital = one new YAML file + `terraform apply`. No HCL changes needed.

## scopes.tf — D2 optional scope assignment

`keycloak_openid_client_optional_scopes.m2m` merges two sets for each M2M client:

1. SMART optional scopes from `config/scopes.yaml`
2. `aud:{target}` for each entry in `allowed_targets`

A caller that requests `scope=aud:hospital-b` gets a token with `aud = fhir_url` of `hospital-b`. Requesting a scope not in the list returns `invalid_scope`.

## The `extra_config` trap — no `attributes.` prefix

`extra_config` on `keycloak_openid_client` maps directly into Keycloak's `attributes` object. **Do not add an `attributes.` prefix to key names** — they will be double-nested (`attributes.attributes.foo`) and silently ignored by Keycloak.

Correct:
```hcl
extra_config = {
  "use.jwks.url" = "true"
  "jwks.url"     = each.value.jwks_url
}
```

Wrong (silently broken):
```hcl
extra_config = {
  "attributes.jwks.url" = "true"   # double-nested, ignored
}
```

## Secrets and Vault

The only secret Terraform needs is the Keycloak admin password. No per-client secrets exist in L2.

```
Vault path: secret/umzh-connect/{env}/keycloak
  admin_password: ...
```

Terraform reads it via the HashiCorp Vault provider:

```hcl
provider "vault" {
  address = var.vault_address
}

data "vault_kv_secret_v2" "keycloak" {
  mount = "secret"
  name  = "umzh-connect/${var.environment}/keycloak"
}

provider "keycloak" {
  client_id = "admin-cli"
  username  = var.keycloak_admin_username
  password  = data.vault_kv_secret_v2.keycloak.data["admin_password"]
  url       = var.keycloak_url
}
```

CI/CD authentication to Vault uses JWT/OIDC (no long-lived credentials). The pipeline's OIDC token is the credential; Vault validates it against the CI provider's JWKS.

For local dev, `var.keycloak_admin_password` falls back to a direct variable (set in `.env`, gitignored).

## Apply commands

Re-apply after any config change:

```sh
# Direct (outside compose network)
TF_VAR_keycloak_url=http://localhost:8180 \
  terraform -chdir=keycloak/terraform apply -auto-approve

# Via compose (uses compose network, keycloak:8080 backchannel URL)
docker compose up keycloak-config
```
