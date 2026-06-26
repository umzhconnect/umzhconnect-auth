---
recap: "Audience claim design — D2 (named aud: scopes) implemented via standard KC scope and audience mapper machinery; no experimental feature dependency."
keywords: [aud claim, audience, ADR 0002, ADR 0003, ADR 0004, ADR 0005, D2, named aud scopes, aud:hospital-b, include_in_token_scope, included_custom_audience, scope-based audience, fhir_url, allowed_targets, keycloak_openid_client_scope, aud_scope, aud_scope_mapper, clients.tf, scopes.tf, one client per hospital]
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

`allowed_targets` in each hospital YAML controls which `aud:` scopes are assigned as optional scopes on each M2M client. A hospital not in `allowed_targets` does not have the `aud:hospital-b` scope on their client — requesting it returns `invalid_scope`.

```yaml
# hospital-a.yaml
fhir_url: "https://fhir.hospital-a.example/fhir"
allowed_targets:
  - "hospital-b"
  - "hospital-c"
```

Terraform (`clients.tf`) creates `aud:` scopes for all hospitals; `scopes.tf` assigns `aud:hospital-b` and `aud:hospital-c` as optional scopes on `hospital-a`'s M2M client.

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

1. Create `config/hospitals/{org_id}.yaml` with `fhir_url`, `jwks_url`, and `allowed_targets`.
2. Run `terraform apply` — KC creates the M2M client, the `aud:{org_id}` scope, and assigns the permitted `aud:` scopes as optional on the new client and any client that lists the new hospital in its `allowed_targets`.

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
