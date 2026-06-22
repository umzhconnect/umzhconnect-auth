# 0002 — Audience claim design: one KC client per (app, target FHIR server)

**Status:** Accepted  
**Date:** 2026-06-17  
**Authors:** Trifork

---

## Context

Keycloak's default `client_credentials` token sets `aud` to the `client_id`. The IG requires `aud` = the target FHIR server base URL (RFC 7519 §4.1.3). Without a correct `aud`, tokens issued for one FHIR server can be replayed at another, and any resource server implementing strict audience validation will reject them outright.

Three designs were evaluated:

| | D1: one client per (app, target) | D2: named aud scopes | D3: RFC 8707 `resource` param |
|---|---|---|---|
| `aud` = FHIR URL | ✅ | ✅ | ✅ |
| Feasible with KC 26.6.1 | ✅ | ✅ | ❌ |
| Client count at N orgs, M apps | O(N × M × N) | O(N × M) | O(N × M) |
| Per-audience scope enforcement at AS | ✅ natural | ❌ not possible | ✅ native (when available) |

**D2** was the initial recommendation, but was ruled out when per-audience scope enforcement became a requirement: D2 keeps one KC client per app and uses optional `aud:<key>` scopes to select the audience, but the AS will grant any scope the client holds regardless of which `aud:` scope is also requested. Enforcing different scope sets per target FHIR server requires separate KC clients.

**D3** (RFC 8707 `resource` parameter) is not available in KC 26.6.1. It is milestoned for KC 26.8.0 as experimental. See [keycloak/keycloak#47117](https://github.com/keycloak/keycloak/issues/47117).

---

## Decision

**D1 — one Keycloak client per (org, app, target FHIR server), generated from YAML config.**

- One KC client per (app, target FHIR server) pair. KC client ID: `{org_id}--{app_id}--{server_key}`.
- Each client has exactly one audience scope assigned as a default scope; the audience mapper sets `aud` = the FHIR server URL.
- Scope set per client is fixed at provisioning time — the AS enforces it, not the client.
- Config is split into two YAML layers owned by different parties:
  - `config/apps/{org_id}--{app_id}.yaml` — app identity (JWKS URL, org metadata, declared scopes). Owned by the calling org.
  - `config/grants/{server_key}.yaml` — access rights granted per calling app. Owned by the org operating that FHIR server.
- A registered app with no grant entries produces no KC clients — registration does not imply access.
- L1 (`client_secret`) is banned from production. All clients are L2 (`private_key_jwt`).

---

## Consequences

- At 20 hospitals × 5 apps × 19 target FHIR servers: ~1 900 KC clients worst case. Keycloak handles this without performance concern — token issuance is a single indexed DB lookup by `client_id`.
- Operators never touch the KC admin console. All KC objects are Terraform-managed.
- Per-audience scope enforcement is clean and explicit: what a client can do is determined entirely by the grants file of the target FHIR server's owner.
- Revoking access to one FHIR server = removing one entry from that server's grants file and running `terraform apply`. The KC client is destroyed.
- Onboarding a new calling app: PR to `config/apps/`; then one or more PRs to the relevant `config/grants/` files (owned by the target orgs).

---

## Revisit when

RFC 8707 `resource` parameter support reaches **preview** status in a Keycloak release and the Terraform provider exposes it. At that point D3 becomes viable: the grants YAML stays the same (it becomes the per-client resource allow-list), the fan-out loop in `clients.tf` is replaced by a single client per app with an allowed-resource list, and the token request switches from `client_id={org}--{app}--{server}` to `client_id={org}--{app} resource={url}`. Track [keycloak/keycloak#47118](https://github.com/keycloak/keycloak/issues/47118).
