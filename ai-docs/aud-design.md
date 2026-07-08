---
recap: "Audience claim design — constant ecosystem aud on every token (ADR 0003). No per-target aud mechanism; D2 named aud: scopes and allowed_clients were removed."
keywords: [aud claim, audience, ADR 0002, ADR 0003, ecosystem_audience, ecosystem-audience-mapper, clients.tf, scopes.tf, one client per hospital]
---

# Audience (`aud`) claim design

**Status:** Implemented — constant ecosystem `aud` on every token. See [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

---

## Current implementation

Every M2M client carries an `ecosystem-audience-mapper` protocol mapper (`clients.tf`) that always writes a single constant value — the realm issuer URL (`${keycloak_url}/realms/umzh-connect`) — into `aud`, regardless of requested scopes. There is no per-target `aud` binding and no per-hospital inbound allow-list; any FHIR server in the realm accepts any token, and is responsible for its own authorization.

Target-specific `aud` binding via RFC 8707 (`resource=` parameter) is deferred until Keycloak's `resource-indicators` feature is non-experimental. See [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md) for the full rationale, RFC analysis, and history of the designs that preceded this one (RFC 8707 resource indicators, then D2 named `aud:` scopes gated by an `allowed_clients` allow-list — both since removed).

### Token request flow

```
POST /realms/umzh-connect/protocol/openid-connect/token
  grant_type=client_credentials
  client_id=hospital-a
  client_assertion=<JWT>
  client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
  scope=system/Task.cru system/ServiceRequest.rs system/Patient.r
```

Every issued token carries `aud = ${keycloak_url}/realms/umzh-connect`, independent of the requested scope.

---

## Adding a hospital

1. Create `config/hospitals/{org_id}.yaml` with `org_id`, `org_display_name`, `org_reference`, `fhir_url`, and `jwks_url`.
2. Run `terraform apply` — KC creates the M2M client and its protocol mappers, including the constant ecosystem audience mapper.

No allow-list configuration is needed; there is no cross-hospital audience mechanism to gate.

---

## Prior designs — superseded

### D2 named `aud:` scopes
`aud:{org_id}` named scopes, gated by an `allowed_clients` allow-list per hospital, were briefly the default audience binding. Fully removed (not just superseded) in [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md) in favour of the constant ecosystem audience — see that ADR for why the mechanism was deleted rather than kept dormant.

### RFC 8707 / resource indicators
`resource=<fhir_url>` parameter; `--features=resource-indicators` experimental KC feature. Replaced by D2 to eliminate the experimental feature dependency, then removed along with D2 by [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

### Original deferred audience (2026-06-23, before D2/RFC 8707)
`aud` defaulted to the KC client ID; no FHIR-server binding. This is the direct ancestor of the current constant-audience default, minus the RFC 8707/D2 detour documented in [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

### D1-via-YAML
One KC client per (org, app, target FHIR server). Replaced by [ADR 0002](../docs/adr/0002-one-client-per-hospital.md).

---

## Next milestone

Scope enforcement at the AS level is still deferred to the Policy Server milestone. When that arrives, layer per-(caller, target) scope grants on top of whichever audience-binding mechanism is active at that time.
