---
recap: "Audience claim design — D2 (named aud: scopes) implemented via standard KC scope and audience mapper machinery; no experimental feature dependency."
keywords: [aud claim, audience, ADR 0002, ADR 0003, ADR 0004, ADR 0005, ADR 0006, D2, named aud scopes, aud:hospital-b, include_in_token_scope, included_custom_audience, scope-based audience, fhir_url, allowed_clients, keycloak_openid_client_scope, aud_scope, aud_scope_mapper, clients.tf, scopes.tf, one client per hospital]
---

# Audience (`aud`) claim design

**Status:** Implemented — D2 (named `aud:` scopes) via standard KC scope machinery. See [ADR 0005](../docs/adr/0005-d2-named-aud-scopes.md).

---

## Current implementation

### Hospital clients (`{org_id}`)

One Keycloak client per hospital, L2 (`private_key_jwt`) only. Declared in `config/hospitals/{org_id}.yaml`.

### Realm-level `aud:` scopes

One KC client scope named `aud:{org_id}` per hospital. Each scope carries an audience mapper with `included_custom_audience = fhir_url`. The scope name is suppressed from the token's `scope` claim (`include_in_token_scope = false`), so only `aud` is affected.

### Explicit allow-list

`allowed_clients` in each hospital YAML controls which M2M clients may request a token with that hospital as audience. A client not listed in the target hospital's `allowed_clients` does not have the `aud:{target}` scope on their client — requesting it returns `invalid_scope`.

```yaml
# hospital-b.yaml — hospital-b decides who may call it
fhir_url: "https://fhir.hospital-b.example/fhir"
allowed_clients:
  - "hospital-a"
  - "hospital-c"
```

Terraform (`clients.tf`) creates `aud:` scopes for all hospitals; `scopes.tf` assigns `aud:hospital-b` as an optional scope on `hospital-a` and `hospital-c` because both appear in `hospital-b.allowed_clients`. See [ADR 0006](../docs/adr/0006-allowed-clients-hospital-controls-inbound-access.md).

### Token request flow

```
POST /realms/umzh-connect/protocol/openid-connect/token
  grant_type=client_credentials
  client_id=hospital-a
  client_assertion=<JWT>
  client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
  scope=aud:hospital-b
```

KC grants `aud:hospital-b` (an optional scope assigned to `hospital-a`), fires the audience mapper, and writes `https://fhir.hospital-b.example/fhir` into the token's `aud`. The scope name itself does not appear in the token's `scope` claim.

### `aud` value in the token

`included_custom_audience = fhir_url` on the scope's audience mapper. Identical to what RFC 8707 produced. Token validators (`EXPECTED_AUDIENCE`) need no change.

---

## Adding a hospital

1. Create `config/hospitals/{org_id}.yaml` with `fhir_url`, `jwks_url`, and `allowed_clients` (the hospitals permitted to target the new one).
2. To allow the new hospital to target existing ones, add its `org_id` to `allowed_clients` in those hospitals' YAML files.
3. Run `terraform apply` — KC creates the M2M client, the `aud:{org_id}` scope, and assigns `aud:` scopes on all clients permitted by the updated allow-lists.

---

## Prior designs — superseded

### RFC 8707 / resource indicators (ADR 0004)
`resource=<fhir_url>` parameter; `--features=resource-indicators` experimental KC feature. Replaced by D2 to eliminate the experimental feature dependency. See [ADR 0005](../docs/adr/0005-d2-named-aud-scopes.md).

### Deferred audience (ADR 0003, before ADR 0004)
`aud` defaulted to the KC client ID; no FHIR-server binding.

### D1-via-YAML (before ADR 0002)
One KC client per (org, app, target FHIR server). Replaced by ADR 0002.

---

## Next milestone

Scope enforcement at the AS level is still deferred to the Policy Server milestone. When that arrives, layer per-(caller, target) scope grants on top of the existing audience binding.
