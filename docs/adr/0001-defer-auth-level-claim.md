# 0001 — Defer `auth_level` claim until L3 is introduced

**Status:** Superseded by [0004](0004-reinstate-l1-debug-client.md)
**Date:** 2026-06-19  
**Authors:** Trifork

---

## Context

The UMZH Connect IG defines three client authentication levels:

- **L1** — `client_secret` (sandbox/PoC only; banned from production)
- **L2** — `private_key_jwt` with JWKS registered at onboarding (production baseline)
- **L3** — mTLS or DPoP (out of scope for the current implementation phase)

A resource server performing token introspection may want to know which authentication level the client used, for example to enforce a minimum level policy or for audit purposes.

The question was raised whether to introduce a custom claim — proposed as `extensions.umzhconnect.auth_level` — in the access token to carry this information.

The implementation would use Keycloak's `keycloak_openid_hardcoded_claim_protocol_mapper` (the same pattern as the existing `org-reference-mapper` and `tenant-mapper`), with the value set at provisioning time from the client's YAML config. No custom Java mapper would be needed. The claim would appear automatically in the introspection response.

---

## Decision

**Defer implementation.** No `auth_level` claim is added at this time.

The current architecture provisions all production clients exclusively at L2 by construction: L1 clients are explicitly prohibited in production, and L3 is out of scope. With only one level in use, the claim carries no distinguishing information. Introducing it now would add infrastructure with no consumer.

When L3 is introduced, the claim will be added at that point. Because the claim is optional (absent today), any resource server or introspection consumer written in the meantime should treat a missing `auth_level` as implying `"L2"` — the only level that can be in use.

---

## Consequences

- Access tokens issued today do not contain `auth_level`. Introspection responses do not include it.
- Resource servers must not require the claim to be present. A missing claim means L2.
- When L3 clients are onboarded, `auth_level` will be added as an optional field in `config/clients/<hospital>.yaml` (default: `"L2"`) and emitted via a hardcoded claim mapper in `clients.tf`. No Java code or image rebuild will be required.
- The YAML default of `"L2"` means existing hospital YAML files will not need to be updated when the claim is introduced.

---

## Revisit when

L3 (`private_key_jwt` + mTLS or DPoP) client onboarding begins.

---

## Superseded

[ADR 0004](0004-reinstate-l1-debug-client.md) reinstates L1 (`client_secret`)
as an opt-in per-hospital debug client. This deferral's premise — "only one
level in use, so the claim carries no distinguishing information" — no
longer holds once L1 and L2 clients coexist, so the `auth_level` claim is
now implemented as described in ADR 0004.
