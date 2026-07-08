---
recap: "Audience claim design — constant ecosystem aud by default (ADR 0003); D2 named aud: scopes kept dormant as a per-hospital fallback for target-specific binding."
keywords: [aud claim, audience, ADR 0002, ADR 0003, D2, ecosystem_audience, ecosystem-audience-mapper, named aud scopes, aud:hospital-b, include_in_token_scope, included_custom_audience, scope-based audience, fhir_url, allowed_clients, keycloak_openid_client_scope, aud_scope, aud_scope_mapper, clients.tf, scopes.tf, one client per hospital]
---

# Audience (`aud`) claim design

**Status:** Implemented — constant ecosystem `aud` by default. See [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

---

## Current implementation

### Default: constant ecosystem audience

Every M2M client carries an `ecosystem-audience-mapper` protocol mapper (`clients.tf`) that always writes a single constant value — the realm issuer URL (`${keycloak_url}/realms/umzh-connect`) — into `aud`, regardless of requested scopes. This is the default for all token requests; it does not bind `aud` to a specific FHIR server.

Target-specific `aud` binding via RFC 8707 (`resource=` parameter) is deferred until Keycloak's `resource-indicators` feature is non-experimental. See [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md) for the full rationale and RFC analysis.

### Fallback: D2 named `aud:` scopes (dormant by default)

Not requested by default. Available for a hospital pair that needs target-specific `aud` isolation before RFC 8707 is viable in Keycloak — see [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

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

Terraform (`clients.tf`) creates `aud:` scopes for all hospitals; `scopes.tf` assigns `aud:hospital-b` as an optional scope on `hospital-a` and `hospital-c` because both appear in `hospital-b.allowed_clients`. The target hospital owns its own inbound allow-list — see [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

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

### D2 as the default
`aud:{org_id}` named scopes were briefly the default audience binding for every token. Superseded by the constant-ecosystem-audience default in [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md); the mechanism itself is retained as the dormant fallback described above.

### RFC 8707 / resource indicators
`resource=<fhir_url>` parameter; `--features=resource-indicators` experimental KC feature. Replaced by D2 to eliminate the experimental feature dependency, then superseded along with D2 by [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

### Original deferred audience (2026-06-23, before D2/RFC 8707)
`aud` defaulted to the KC client ID; no FHIR-server binding. This is the direct ancestor of the current constant-audience default, minus the RFC 8707/D2 detour documented in [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

### D1-via-YAML
One KC client per (org, app, target FHIR server). Replaced by [ADR 0002](../docs/adr/0002-one-client-per-hospital.md).

---

## Next milestone

Scope enforcement at the AS level is still deferred to the Policy Server milestone. When that arrives, layer per-(caller, target) scope grants on top of the existing audience binding.
