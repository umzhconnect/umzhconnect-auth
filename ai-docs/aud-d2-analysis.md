---
recap: "Historical. D2 (named aud scopes, one client per hospital) was implemented as the default, then removed entirely in favour of a constant ecosystem aud (ADR 0003). Analysis of D2 vs RFC 8707 as alternatives, kept for reference if target-specific aud is rebuilt later."
keywords: [D2, named aud scopes, aud:hospital-a, scope-based audience, include_in_token_scope, included_custom_audience, resource-indicators, experimental feature risk, D2 feasibility, U5, per-audience scope enforcement, ADR 0002, ADR 0003, RFC 8707, ecosystem-audience-mapper]
---

# D2 audience design — feasibility analysis

**Status:** Historical / removed. D2 was implemented as the default, then removed entirely (not kept as a fallback) in favour of a constant ecosystem `aud` — see [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md). This analysis is kept for reference only, in case target-specific `aud` binding is rebuilt in the future. See [aud-design.md](aud-design.md) for the current implementation.

---

## Background

The original design exploration considered three approaches to binding `aud` in M2M tokens:

| Design | Mechanism | Status |
|--------|-----------|--------|
| D1-via-YAML | One KC client per (org, app, FHIR server) | Superseded by ADR 0002 |
| D2 | Named `aud:` scopes on the realm; caller requests `scope=aud:hospital-b` | Implemented, then removed by [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md) |
| D3 / RFC 8707 | `resource=<fhir_url>` parameter; KC resolves against registered resource_url values | Implemented, then removed — blocked on KC's experimental support, see [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md) |

D2 was ruled out when per-audience scope enforcement was a requirement: in D2, the AS grants any scope the client holds regardless of which `aud:` scope is requested, so you cannot enforce different SMART scope sets per target FHIR server without separate KC clients.

That requirement was explicitly dropped in ADR 0002 and ADR 0003. FHIR servers are responsible for their own authorization; the AS's role is authentication and audience binding only. The original veto no longer applies.

---

## What D2 looks like in the current model

No structural changes to the hospital model. Everything that is today driven from `config/clients-l2/*.yaml` continues as-is.

### KC objects

| Object | RFC 8707 (current) | D2 |
|--------|-------------------|-----|
| M2M client `{client_id}` | ✅ one per hospital | ✅ same |
| FHIR resource-server client `{client_id}-fhir-server` | ✅ one per hospital | ❌ not needed |
| Realm-level client scope `aud:hospital-b` | ❌ | ✅ one per hospital |
| Audience mapper on scope | ❌ | ✅ `included_custom_audience = fhir_url` |
| Audience mapper on M2M client (cross-hospital) | ✅ per `allowed_targets` pair | ❌ replaced by optional scope assignment |

### Explicit allow-list

`allowed_targets` in each hospital YAML still controls access. In D2, Terraform translates it to: assign `aud:hospital-b` as an **optional scope** on the `hospital-a` M2M client (rather than creating a `keycloak_openid_audience_protocol_mapper` per pair). A hospital not in `allowed_targets` cannot obtain a token scoped to that target.

### `include_in_token_scope = false`

Setting this on every `aud:` scope suppresses the scope name from the `scope` claim in the token. The audience mapper fires independently, so the token carries the correct `aud` without `aud:hospital-b` appearing in `scope`.

### Token request

```
POST /realms/umzh-connect/protocol/openid-connect/token
  grant_type=client_credentials
  client_id=hospital-a
  client_assertion=<JWT>
  client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
  scope=aud:hospital-b
```

vs. RFC 8707:

```
  resource=https://fhir.hospital-b.example/fhir
```

### `aud` value in the token

Using `included_custom_audience = fhir_url` on the scope's audience mapper puts the actual FHIR server URL in `aud` — identical to what RFC 8707 produces. Token validators (e.g. `EXPECTED_AUDIENCE` in token-validator) would need no change.

---

## Trade-off: D2 vs RFC 8707

### D2 advantages

**No experimental KC feature dependency.** `resource-indicators` is still labelled experimental in KC 26.6.1. D2 uses standard KC scope and audience mapper machinery — no feature flag, no version pin, no risk of the feature being renamed or broken on KC upgrade.

**Fewer KC objects.** The `{client_id}-fhir-server` registration clients (one per hospital) are not needed. The Terraform `fhir_resource_server` resource block and the `depends_on` workaround on `cross_hospital` mappers disappear.

**No KC bug workaround.** `use_refresh_tokens_client_credentials = true` is required on all M2M clients to avoid an NPE in KC when `resource-indicators` is active ([keycloak/keycloak#50251](https://github.com/keycloak/keycloak/issues/50251)). D2 doesn't trigger this.

**Simpler Terraform.** The `audience_pairs` cross-product local becomes an optional scope assignment loop. Fewer resource types, less indirection.

### RFC 8707 advantages

**Caller uses the FHIR URL directly.** `resource=https://fhir.hospital-b.example/fhir` is self-documenting and doesn't require the caller to know KC's internal scope naming convention. Hospital FHIR clients and SMART on FHIR tooling already understand the `resource` parameter.

**Cleaner error on unknown target.** RFC 8707 returns `invalid_target` when `resource=` doesn't match any registered URL — an unambiguous protocol-level rejection. D2 returns a generic OAuth `invalid_scope` error, which is correct but less precise.

**Aligns with the IG trajectory.** The SMART on FHIR ecosystem is moving toward `resource` parameter usage. If `umzhconnect-ig` adopts RFC 8707, the current implementation is already aligned.

**Already implemented and tested.** UMZH's sandbox PR ([umzhconnect-sandbox#31](https://github.com/umzhconnect/umzhconnect-sandbox/pull/31)) validated the feature on KC 26.6.1. Switching to D2 would be a working-backwards step.

---

## Summary

D2 is fully implementable with no missing pieces. It trades the experimental feature risk (currently accepted) for a slightly less natural API for FHIR callers and weaker error semantics. RFC 8707 is the better long-term fit if the IG and SMART ecosystem continue moving in that direction; D2 is the safer fallback if the experimental feature causes problems on a KC upgrade.

No action required unless the experimental feature risk materialises.
