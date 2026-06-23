---
recap: "Audience claim design — D1 (one KC client per app+target) is implemented; D2 was ruled out; D3 (RFC 8707) is the tracked future migration."
keywords: [aud claim, Design 1, Design 2, Design 3, RFC 8707, resource parameter, audiences.tf, fhir-servers.yaml, aud:fhir-hospital-a-referral, include_in_token_scope, keycloak/keycloak#47117, keycloak/keycloak#47118, per-audience scope enforcement, D1-via-YAML, KC client per app target, D2 ruled out, ADR 0002]
---

# Audience (`aud`) claim design

**Status:** D1-via-YAML implemented. D3 migration path documented.  
Full rationale: [`docs/adr/0002-audience-claim-design.md`](../docs/adr/0002-audience-claim-design.md)  
Architecture detail: [`audience_architecture.md`](../audience_architecture.md)

---

## Implemented: D1-via-YAML

One Keycloak client per (org, app, target FHIR server), generated from YAML config. Each client has exactly one `aud:<server_key>` scope assigned as a **default scope** — the audience mapper sets `aud` = the FHIR server URL without the client needing to request it.

`include_in_token_scope = false` on the scope suppresses `aud:fhir-hospital-a-referral` from the `scope` claim — the audience mapper fires independently, so the token has the correct `aud` but no noise in `scope`.

Scope enforcement is at the AS level: the granted SMART scopes are fixed at provisioning time per (app, target FHIR server) pair. Different targets can have different scope sets for the same calling app.

---

## Why D2 was ruled out

D2 (named aud scopes, one client per app) was the initial recommendation but was rejected when per-audience scope enforcement became a requirement. In D2, the AS grants any scope the client holds regardless of which `aud:` scope is requested — there is no mechanism to enforce different scope sets per target FHIR server without separate KC clients. D1 gives this naturally.

---

## Why D3 is not available yet

RFC 8707 `resource` parameter support in Keycloak is tracked as [keycloak/keycloak#47117](https://github.com/keycloak/keycloak/issues/47117) (experimental) and [#47118](https://github.com/keycloak/keycloak/issues/47118) (preview). Not available in KC 26.6.1. Milestoned for KC 26.8.0 as experimental — no stable release date.

---

## D3 migration path (when available)

| | D1-via-YAML (now) | D3 (future) |
|---|---|---|
| KC clients | 1 per (app, FHIR server) | 1 per app |
| `config/apps/` | unchanged | unchanged |
| `config/grants/` | drives client generation | becomes per-client resource allow-list |
| Token request | `client_id=hospital-b--lis--fhir-hospital-a-referral` | `client_id=hospital-b--lis resource=https://...` |

Migration is low-effort when D3 reaches preview: the YAML config stays the same, the fan-out loop in `clients.tf` is replaced, and clients switch token request parameters.
