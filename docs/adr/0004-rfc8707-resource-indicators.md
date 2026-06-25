# ADR 0004 — RFC 8707 resource indicators for audience binding

**Status:** Accepted — supersedes [ADR 0003](0003-defer-scope-and-audience-enforcement.md) (audience enforcement deferred)

---

## Context

ADR 0003 deferred audience binding at the AS level because KC's RFC 8707 (`resource_indicators`) support was not production-ready. The deferral condition was: _"when RFC 8707 support reaches preview in Keycloak (tracked as keycloak/keycloak#47117 — milestoned for KC 26.8.0 as experimental)"_.

Michael Rebsamen (USZ/UMZH) opened [umzhconnect-sandbox#31](https://github.com/umzhconnect/umzhconnect-sandbox/pull/31) on 2026-06-24 demonstrating that the `resource-indicators` experimental feature works on KC 26.6.1 — the version we already run — including L2 (`private_key_jwt`) clients. This resolves the technical blocker described in ADR 0003.

The feature is still labelled experimental in Keycloak. The sandbox PR was a draft when this ADR was written.

---

## Decision

Enable `--features=resource-indicators` in KC at build time and enable audience binding via:

1. **FHIR resource-server clients** (`{org_id}-fhir-server`) — one per hospital, carrying `resource_url = fhir_url` from the hospital YAML. These are not OAuth clients (no flows, no service account) — they exist solely for KC to match the `resource=` parameter.

2. **Explicit allow-list** (`allowed_targets` in each hospital YAML) — controls which cross-hospital audience mappers are created. A hospital not listed in `allowed_targets` cannot receive a token scoped to it, regardless of what `resource=` the caller sends.

3. **`use_refresh_token` workaround** — `client_credentials.use_refresh_token = true` on all M2M clients, required to avoid a KC NPE when `resource-indicators` is active (keycloak/keycloak#50251).

Token requests now include `resource=<fhir_url>`. KC validates the URL against registered `resource_url` values and restricts `aud` to the matched resource-server client ID. Unknown URIs are rejected with `invalid_target`.

What was ruled out:

- **Implicit all-to-all**: auto-generating audience mappers for every (source ≠ target) pair would violate the "no implicit access" principle from ADR 0002.
- **Waiting for KC 26.8.0 stable**: the sandbox already validates the feature on 26.6.1; no reason to block on the stable milestone.

---

## Consequences

- `aud` in M2M tokens is now bound to a specific FHIR server URL when `resource=` is supplied. FHIR servers can enforce this (EXPECTED_AUDIENCE in token-validator).
- Adding a new hospital requires `fhir_url` and `allowed_targets` in the YAML. Omitting either means the hospital cannot participate in cross-hospital token flows.
- The feature is experimental — KC could rename or break it. Pin the KC version (`26.6.1`) and review on each KC upgrade.
- If KC removes the feature before it stabilises, the fallback is the pre-ADR-0003 state (aud = client_id, no FHIR-server binding).

---

## Revisit when

- KC promotes `resource-indicators` from experimental to supported/preview (expected ~26.8.0). Audit the feature contract at that point for any breaking changes.
- The Policy Server milestone is reached — at that point scope enforcement at the AS level should be layered on top of audience binding.
