# 0003 — Constant ecosystem `aud`, deferring RFC 8707 until Keycloak support matures

**Status:** Accepted
**Date:** 2026-07-08
**Authors:** Trifork

**Consolidates:** this ADR replaces all prior, now-retired decision records about the `aud` claim and the target-hospital allow-list with this single record.

---

## Context

This ADR consolidates several earlier, sequential decisions about the `aud` claim into one record. The full history:

1. **Original deferral (2026-06-23 meeting).** UMZH confirmed that neither scope nor audience enforcement should be applied at the AS level yet: FHIR servers perform their own authorization, and enforcement properly belongs to a future Policy Server. `aud` was left at the KC default (the client ID); no per-target binding was implemented.

2. **RFC 8707 resource indicators.** UMZH demonstrated that KC's `resource-indicators` feature — the standard mechanism for a caller to request a specific audience via a `resource=` parameter — works on KC 26.6.1, including for L2 (`private_key_jwt`) clients. This was implemented: per-hospital resource-server stub clients, an explicit `allowed_targets` allow-list, and a KC NPE workaround (`use_refresh_token`).

3. **D2 named `aud:` scopes.** The `resource-indicators` feature remained labelled experimental in Keycloak, which was judged an unacceptable production dependency. It was replaced with a design using only standard, non-experimental KC scope and audience-mapper machinery: one realm-level scope `aud:{org_id}` per hospital, each carrying an audience mapper that writes the hospital's FHIR URL into `aud`. A caller requests `scope=aud:hospital_b`; assignment of that optional scope was controlled by an allow-list in the target hospital's YAML (`allowed_targets`, later renamed `allowed_clients` to invert ownership onto the target hospital — the resource owner, not the caller, controls its own inbound access).

The standards analysis behind these decisions ([ai-docs/aud-rfc-backing.md](../../ai-docs/aud-rfc-backing.md)) established:

- **RFC 7519** makes `aud` optional; a constant, domain-wide value is syntactically valid but forfeits the isolation the claim is meant to provide.
- **RFC 9068** (JWT profile for OAuth access tokens) makes `aud` *required* and expects it to identify the actual resource server(s), preferably derived from a `resource` parameter — but explicitly permits inferring `aud` from the `scope` parameter when no `resource` parameter is present (§3). This is the normative basis the D2 `aud:hospital_b` scope pattern relied on.
- **RFC 8707** (resource indicators) is the target standard for explicit, per-request audience binding via `resource=`. Keycloak's support for it remains behind an experimental feature flag.

This is where the present decision departs from the D2 approach above: rather than keeping target-specific `aud:` scopes and their allow-list, we are stepping back to a single constant `aud` for all tokens, with no per-target mechanism at all.

---

## Decision

**Target state:** comply with RFC 9068, and with RFC 8707 for populating `aud` once Keycloak supports it non-experimentally.

**Current state, until then:**

- Keycloak's `resource-indicators` implementation of RFC 8707 is experimental only. We will not build on it in production. This rules out `--features=resource-indicators`, the per-hospital resource-server stub clients, and the `use_refresh_token` workaround from the RFC 8707 attempt described above — none of that is reinstated.
- Target/resource-server-specific `aud` binding is deferred until an integrated service strictly requires it. We expect RFC 8707 to become a near-term priority for Keycloak, and will re-evaluate its support each time we upgrade the KC version pinned in this repo.
- `aud` is set to a single constant value identifying the umzh-connect ecosystem as a whole (the realm issuer URL) for every token, rather than a per-target FHIR URL. This is a knowing, looser reading of RFC 9068 — the claim no longer identifies a specific resource server — accepted as the pragmatic interim given no experimentally-stable path to RFC 8707 exists yet.
- The D2 `aud:{org_id}` named-scope mechanism and its `allowed_clients` allow-list are **removed**, not kept dormant: `clients.tf`'s `aud_scope` / `aud_scope_mapper` resources, `scopes.tf`'s allow-list-driven optional-scope wiring, and the `allowed_clients` field in each hospital's YAML are all deleted. There is no per-hospital inbound allow-list of any kind. If a specific integration later needs target-specific `aud` isolation, it will be rebuilt at that time with whichever mechanism (D2, RFC 8707, or something else) fits Keycloak's support at that point — not kept on standby indefinitely.

What was ruled out:

- **Re-attempting RFC 8707 now**: still blocked on the same experimental-feature risk described above.
- **Keeping the D2 scope mechanism dormant**: initially considered, but rejected in favour of a clean removal — an allow-list field with nothing gating it (`allowed_clients` with no consumer) is dead config that invites confusion about what it still does.
- **Omitting `aud` entirely**: RFC 9068 makes it required.

---

## Consequences

- **Token isolation risk returns.** A token is not bound to a specific FHIR server URL. Any FHIR server in the realm will accept a token bearing the constant ecosystem `aud`. This is the same risk profile as the original 2026-06-23 deferral. FHIR servers remain responsible for their own access control.
- **Looser RFC 9068 conformance.** `aud` is required and present, but does not identify the actual resource server — a deliberate, documented deviation rather than an oversight.
- **Simpler Terraform and config.** No resource-server stub clients, no `resource=` handling, no `aud:{org_id}` scopes, no `allowed_clients` field in hospital YAML. Onboarding a hospital requires only `client_id`, `client_name`, `organization_reference`, `fhir_url`, `jwks_url`, and `auth_level`.
- **No standing escape hatch.** Unlike the interim state considered during this decision, there is currently no per-hospital mechanism to request target-specific audience isolation. Building one is future work, not a flag flip.

---

## Revisit when

- Keycloak promotes `resource-indicators` from experimental to supported/preview — evaluate adopting RFC 8707 at that point.
- An integrated FHIR server or hospital demonstrates a concrete need for target-specific audience isolation before RFC 8707 is production-ready — design and build the mechanism then, informed by whatever Keycloak supports at that time.
- The Policy Server milestone is reached — layer scope enforcement per (caller, target) on top of whichever audience-binding mechanism is active at that time.
