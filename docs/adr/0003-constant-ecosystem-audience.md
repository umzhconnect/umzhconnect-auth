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

3. **D2 named `aud:` scopes.** The `resource-indicators` feature remained labelled experimental in Keycloak, which was judged an unacceptable production dependency. It was replaced with a design using only standard, non-experimental KC scope and audience-mapper machinery: one realm-level scope `aud:{org_id}` per hospital, each carrying an audience mapper that writes the hospital's FHIR URL into `aud`. A caller requests `scope=aud:hospital-b`; assignment of that optional scope is controlled by an allow-list in the target hospital's YAML. This is what `clients.tf` / `scopes.tf` implement today.

4. **`allowed_clients` ownership.** The allow-list field was originally named `allowed_targets` and placed on the *requesting* hospital: hospital-a declaring `allowed_targets: [hospital-b]` meant "hospital-a is permitted to target hospital-b." This puts access control in the wrong place — hospital-b has no visibility into, or ability to modify, who may target it. The field was renamed to `allowed_clients` and ownership inverted: each hospital's YAML now declares which clients are permitted to request a token with *that hospital* as audience. The resource owner (the target hospital) controls its own inbound access, consistent with the "no implicit access" principle. This remains the model today and is unaffected by the audience-binding decision below.

The standards analysis behind these decisions ([ai-docs/aud-rfc-backing.md](../../ai-docs/aud-rfc-backing.md)) established:

- **RFC 7519** makes `aud` optional; a constant, domain-wide value is syntactically valid but forfeits the isolation the claim is meant to provide.
- **RFC 9068** (JWT profile for OAuth access tokens) makes `aud` *required* and expects it to identify the actual resource server(s), preferably derived from a `resource` parameter — but explicitly permits inferring `aud` from the `scope` parameter when no `resource` parameter is present (§3). This is the normative basis for the `aud:hospital-b` scope pattern.
- **RFC 8707** (resource indicators) is the target standard for explicit, per-request audience binding via `resource=`. Keycloak's support for it remains behind an experimental feature flag.

This is where the present decision departs from the D2 approach above: rather than keeping target-specific `aud:` scopes as the default behaviour, we are stepping back to a constant `aud` for the common case, and reserving the named-scope mechanism for cases that specifically need it.

---

## Decision

**Target state:** comply with RFC 9068, and with RFC 8707 for populating `aud` once Keycloak supports it non-experimentally.

**Current state, until then:**

- Keycloak's `resource-indicators` implementation of RFC 8707 is experimental only. We will not build on it in production. This rules out `--features=resource-indicators`, the per-hospital resource-server stub clients, and the `use_refresh_token` workaround from the RFC 8707 attempt described above — none of that is reinstated.
- Target/resource-server-specific `aud` binding is deferred until an integrated service strictly requires it. We expect RFC 8707 to become a near-term priority for Keycloak, and will re-evaluate its support each time we upgrade the KC version pinned in this repo.
- In the meantime, `aud` is set to a single constant value identifying the umzh-connect ecosystem as a whole (e.g. the realm issuer URL) rather than a per-target FHIR URL. This is a knowing, looser reading of RFC 9068 — the claim no longer identifies a specific resource server — accepted as the pragmatic interim given no experimentally-stable path to RFC 8707 exists yet.
- The D2 `aud:{org_id}` named-scope mechanism (`clients.tf`'s `aud_scope` / `aud_scope_mapper`, `scopes.tf`'s optional-scope wiring from `allowed_clients`) is **not removed**. It is kept as the documented fallback: if a specific integration needs target-specific `aud` isolation before RFC 8707 is viable in Keycloak, that hospital pair can be switched back to requesting `scope=aud:{target}` without new engineering work. It is no longer the default path for new integrations.
- The `allowed_clients` ownership model (target hospital controls its own inbound allow-list) is unchanged and continues to gate assignment of the D2 fallback scopes.

What was ruled out:

- **Re-attempting RFC 8707 now**: still blocked on the same experimental-feature risk described above.
- **Deleting the D2 scope mechanism**: it has direct RFC 9068 §3 backing and costs nothing to keep dormant; removing it would mean re-implementing it from scratch if a hospital needs target-specific `aud` before RFC 8707 matures.
- **Omitting `aud` entirely**: RFC 9068 makes it required.
- **Reverting `allowed_clients` to caller-owned `allowed_targets`**: the resource-owner-controls-inbound-access rationale is independent of which audience-binding mechanism is active, and still holds.

---

## Consequences

- **Token isolation risk returns for the default path.** A token is not bound to a specific FHIR server URL unless a hospital pair is explicitly switched to the D2 fallback. Any FHIR server in the realm will accept a token bearing the constant ecosystem `aud`. This is the same risk profile as the original 2026-06-23 deferral, now re-accepted after a detour through per-target binding. FHIR servers remain responsible for their own access control.
- **Looser RFC 9068 conformance.** `aud` is required and present, but does not identify the actual resource server — a deliberate, documented deviation rather than an oversight.
- **No new Terraform objects.** No resource-server stub clients, no `resource=` handling. The existing `aud:{org_id}` scopes stay in the codebase unused by default.
- **Per-hospital escape hatch exists.** Any hospital pair that needs isolation sooner can request `scope=aud:{target}` today, using the already-implemented D2 mechanism, gated by that hospital's own `allowed_clients` list, without waiting for RFC 8707.

---

## Revisit when

- Keycloak promotes `resource-indicators` from experimental to supported/preview — re-evaluate adopting RFC 8707 properly at that point, and consider retiring the D2 fallback in its favour.
- An integrated FHIR server or hospital demonstrates a concrete need for target-specific audience isolation before RFC 8707 is production-ready — reactivate the D2 `aud:{target}` scope for that pair rather than building something new.
- The Policy Server milestone is reached — layer scope enforcement per (caller, target) on top of whichever audience-binding mechanism is active at that time.
