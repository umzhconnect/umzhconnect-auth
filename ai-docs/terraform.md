---
recap: "Terraform structure and pitfalls — client_id-driven client generation from config/clients-l2 and config/clients-l1, constant ecosystem aud mapper, extra_config double-nesting trap, Vault secrets, apply commands, and the opt-in L1 debug client path."
keywords: [keycloak/keycloak ~>5.0, extra_config, attributes prefix, double-nesting, jwks.url, use.jwks.url, clients.tf, scopes.tf, realm.tf, yamldecode, local.clients_l2, local.clients_l1, TF_VAR_keycloak_url, keycloak-config, apply command, for_each, config/clients-l2, config/clients-l1, client_id, client_name, organization_reference, jwks_url, vault, vault_kv_secret_v2, admin_password, JWT OIDC, client-id-mapper, client_id claim, RFC 9068, access.token.header.type.rfc9068, at+jwt, org-reference-mapper, fhir-context-mapper, ecosystem_audience, ecosystem-audience-mapper, included_custom_audience, auth_level, lifecycle precondition, m2m_l1, allow_l1_debug_clients, ADR 0003, ADR 0004]
---

# Terraform

Provider: `keycloak/keycloak ~> 5.0` (`keycloak/terraform/versions.tf`).

## File structure

| File | Responsibility |
|------|----------------|
| `clients.tf` | Reads `config/clients-l2/*.yaml` → one L2 KC client per hospital + protocol mappers |
| `realm.tf` | Realm-level settings |
| `variables.tf` | Input variables |
| `outputs.tf` | Outputs (client IDs, etc.) |
| `versions.tf` | Provider version pins |

## clients.tf — how it works

Reads all `*.yaml` files from `config/clients-l2/`. Each file defines one hospital's L2 client and carries its own `client_id` — Terraform builds `local.clients_l2` by keying on that field, not the filename. Creates:
- One `keycloak_openid_client` per hospital with `client-jwt` authenticator, the hospital's `jwks_url`, and `access.token.header.type.rfc9068 = "true"` (RFC 9068 §2.1 `at+jwt` header `typ`)
- `client-id-mapper` — hardcoded claim mapper setting `client_id` to the client's own ID (RFC 9068 §2.2; not Keycloak's built-in Client ID mapper, which names the claim `clientId`)
- `org-reference-mapper` — hardcoded claim mapper setting `extensions.umzhconnect.organization_reference`
- `fhir-context-mapper` — custom protocol mapper for `authorization_details` → `fhirContext`
- `ecosystem-audience-mapper` — audience mapper writing a constant ecosystem value (the realm issuer URL) into `aud` on every token, per [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md)

KC client ID = the file's own `client_id` field (convention: `{hospital}-l2`, e.g. `hospital_a-l2`; the filename is a naming convention only, never read by Terraform).

L2 client YAML schema (`config/clients-l2/{client_id}.yaml`):

```yaml
client_id: "hospital_b-l2"
client_name: "Hospital B"
organization_reference: "https://fhir.hospital-b.example/fhir/Organization/HospitalB"
fhir_url: "https://fhir.hospital-b.example/fhir"
jwks_url: "https://hospital-b.example/.well-known/hospital-b.jwks.json"
auth_level: "L2"
```

Adding a hospital = one new YAML file + `terraform apply`. No HCL changes needed. There is no per-hospital allow-list — [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md) removed the `allowed_clients` field along with the target-specific `aud:{org_id}` scope mechanism it used to gate.

## Optional L1 debug client (`config/clients-l1/`)

`local.clients_l1_all` reads every `config/clients-l1/*.yaml` file, keyed by its own `client_id` field. `local.clients_l1` — what the resources below actually loop over — is that map gated by `var.allow_l1_debug_clients`: it's `clients_l1_all` when the flag is `true`, otherwise `{}`. For each entry in `local.clients_l1`, Terraform creates `keycloak_openid_client.m2m_l1["{client_id}"]` with `client_authenticator_type = "client-secret"` (Keycloak-generated secret, surfaced via the `m2m_l1_client_secrets` sensitive output) and the same mapper set as the L2 client, including its own `auth-level-mapper` sourced from the file's `auth_level` field (must be `"L1"`). The primary L2 client's `auth-level-mapper` is likewise sourced from its file's `auth_level` (must be `"L2"`) — `auth_level` is a required claim on every M2M client, not implied by absence; see [ADR 0004](../docs/adr/0004-reinstate-l1-debug-client.md) (superseding the [ADR 0001](../docs/adr/0001-defer-auth-level-claim.md) deferral) and [config-model.md](config-model.md). A `lifecycle.precondition` on both `m2m` and `m2m_l1` hard-fails `terraform apply` if a file's `auth_level` doesn't match the directory it's in.

**Safeguard:** `allow_l1_debug_clients` (bool, default `false`, in `variables.tf`) gates `local.clients_l1` in every environment, not just `"prod"`. When it's `false`, any `config/clients-l1/*.yaml` file present is silently ignored — no L1 client is created for it — and the `check "l1_debug_clients_ignored"` block (`clients.tf`) emits a plan-time **warning** naming the ignored file(s); it does not fail `terraform apply`. It's a plain input variable, not baked into the `tf-config` image, so it's set per-environment at apply time (`TF_VAR_allow_l1_debug_clients=true` on whichever `keycloak-config` Job should allow L1, left unset/`false` everywhere else) without rebuilding the image. Note: local `docker-compose` does not set this variable, so any `config/clients-l1/*.yaml` file present is ignored (with a warning) rather than provisioned when running `docker compose up keycloak-config` locally, unless `TF_VAR_allow_l1_debug_clients=true` is added to its environment.

## scopes.tf — every scope is optional, none is default

`keycloak_openid_client_optional_scopes.m2m` registers every scope from `config/scopes.yaml` on every M2M client. Requesting a scope not in that list returns `invalid_scope`. `keycloak_openid_client_default_scopes.m2m` is pinned to an empty list — deliberately, so no scope is ever included in an issued token unless the caller requests it in the `scope` parameter. Same pattern for `m2m_l1`.

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
