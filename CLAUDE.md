# CLAUDE.md — Instructions for Claude Code

## Project purpose

Keycloak-based OAuth 2.0 Authorization Server for the UMZH Connect ecosystem,
implementing the IG's machine-to-machine security model. Three deliverables:

| Folder | What | Production? |
|--------|------|-------------|
| `keycloak/` | Custom Keycloak image + Terraform realm config | Yes (image + config) |
| `token-validator/` | Mock resource server that validates tokens | No — dev/test only |
| `bruno/` | Request collection (auth, validation, negative cases) | No |

Key contacts: **David Altorfer** (Trifork project lead), **Andreas Ahlm** and **Michael** (USZ/UMZH side).

---

## Domain context

UMZH Connect is a standardized API ecosystem for sharing clinical data between healthcare organizations. Initial use case: cross-organizational referral workflows (orthopedic surgery, sarcoma tumor boards) between a **Placer** (referring party) and a **Fulfiller** (receiving party). Governed by a FHIR IG at `https://build.fhir.org/ig/umzhconnect/umzhconnect-ig/`.

### FHIR basics

- Everything is a **Resource**: Patient, Condition, ServiceRequest, Task, Consent, etc.
- Resources exposed via RESTful HTTP API; resources reference each other forming a graph.
- An **Implementation Guide (IG)** constrains FHIR for a specific use case.
- Placer hosts a FHIR server with `ServiceRequest` resources; Fulfiller hosts one with `Task` resources.

### SMART on FHIR

- **SMART scopes** — standardized permission language: `system/<ResourceType>.<action>` (e.g. `system/Patient.r`, `system/Task.cru`). The `system/` prefix means M2M, no user logged in.
- **Backend Services** — instead of a client secret, clients authenticate with `private_key_jwt` signed with their private key, validated against registered JWKS. No shared secrets.
- **fhirContext** — client declares which FHIR resource it's operating in context of; ends up as a `fhirContext` claim in the issued JWT for fine-grained RS enforcement.

### The referral flow

```
Fulfiller → Keycloak:
  POST /token
  grant_type=client_credentials
  scope=system/ServiceRequest.rs system/Patient.r
  authorization_details=[{"type":"umzh-connect-context","identifier":"ServiceRequest/sr-123"}]
  client_assertion=<JWT signed with Fulfiller's private key>

Keycloak issues access token:
  {
    "iss": "https://auth.umzhconnect.ch",
    "aud": "https://fhir.placer.example",    ← target FHIR server URL (see Audience gap below)
    "scope": "system/ServiceRequest.rs system/Patient.r",
    "extensions": { "umzhconnect": { "organization_reference": "..." } },
    "fhirContext": [{ "reference": "ServiceRequest/sr-123" }]
  }

Fulfiller → Placer's FHIR server:
  GET /ServiceRequest/sr-123
  Authorization: Bearer <access token>

Placer's policy engine (OPA):
  1. Validate JWT signature and scope
  2. Look up active Consent for ServiceRequest/sr-123 authorizing this party_id
  3. Verify requested resource is within the reference graph of sr-123
  → Allow or deny
```

Context enforcement uses FHIR `Consent` resources (`meaning = "related"` covers the root resource and its transitive references). Revoke by setting `Consent.status = inactive`.

### The full sandbox stack (for reference)

Keycloak 26.6.1, HAPI FHIR, APISIX (API gateway), OPA (fine-grained authz), nginx, PostgreSQL.

---

## Reference repos (cloned at ~/github/umzhconnect/)

| Repo | Role |
|------|------|
| `umzhconnect-ig` | Normative security spec — read `input/pagecontent/security.md` and `security-implementation.md` before making auth decisions |
| `umzhconnect-sandbox` | Running reference implementation; the Keycloak realm contract in this repo must be a drop-in replacement for the sandbox's `keycloak` service |
| `umzhconnect-auth` | Empty skeleton — this repo is what fills it (LICENSE + README only as of 2026-06-15) |

---

## Auth model (IG summary)

- Pure M2M: `client_credentials` grant, no user flows, no `openid` scope.
- **Level 1** (`client_secret`) — sandbox/PoC only.
- **Level 2** (`private_key_jwt`, JWKS registered at onboarding) — production baseline. Level 3 (mTLS/DPoP) is out of scope.
- RFC 9396 `authorization_details` of type `umzh-connect-context` → mapped by the custom `FhirContextMapper` into a `fhirContext` claim.
- Every token carries `extensions.umzhconnect.organization_reference` (set by the AS from the onboarding record, never by the client).
- SMART system scopes: `system/<Resource>.<cruds>`.

---

## Realm contract (must stay sandbox-compatible)

| Item | Value |
|------|-------|
| Realm | `umzh-connect` |
| Issuer (published) | `http://localhost:8180/realms/umzh-connect` |
| Token lifetime | 300 s |
| L1 clients | `placer-client` / `fulfiller-client` (client-secret) |
| L2 clients | `placer-client-l2` / `fulfiller-client-l2` (client-jwt, JWKS fetched from `jwks.url`) |
| Roles | `placer`, `fulfiller`, `admin` |
| Mappers per M2M client | `org-reference-mapper`, `fhir-context-mapper`, `tenant-mapper`, `realm-roles` |

Known divergences from the sandbox `realm-export.json` (all intentional):
- `registrationAllowed = false` (sandbox has `true` for web-app login).
- `display_name = "UMZH Connect"` (sandbox says `"UMZH Connect Sandbox"`).
- Keycloak's built-in scopes (`email`, `profile`, `roles`, etc.) are present here; the sandbox export omits them (they exist in Keycloak but weren't exported).

---

## Terraform

Provider: `keycloak/keycloak ~> 5.0`.

`extra_config` on `keycloak_openid_client` maps directly into Keycloak's
`attributes` object — **do not add an `attributes.` prefix** to key names or
they will be double-nested (`attributes.attributes.foo`) and silently ignored
by Keycloak. The JWKS URL for L2 clients is set via:

```hcl
extra_config = {
  "use.jwks.url" = "true"
  "jwks.url"     = var.placer_l2_jwks_url   # NOT "attributes.jwks.url"
}
```

Re-apply after config changes:
```sh
TF_VAR_keycloak_url=http://localhost:8180 \
  terraform -chdir=keycloak/terraform apply -auto-approve
```

`docker compose up keycloak-config` does the same via the compose network.

---

## FhirContextMapper

Source: `keycloak/mapper/` (ported from umzhconnect-sandbox, Apache-2.0).

Keycloak 26.x does not populate `AuthorizationRequestContext` with custom
`authorization_details` types for the `client_credentials` flow. The mapper
reads the raw session notes (`authorization_details` /
`client_request_param_authorization_details`) directly. Do not attempt to use
the standard `AuthorizationRequestContext` API for this — it only contains
built-in SMART scope entries.

The mapper is bundled into the image at build time (multi-stage Dockerfile).
No runtime volume mount needed.

---

## docker-compose

`KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` lets in-network services (Terraform,
token-validator) reach Keycloak at `http://keycloak:8080` while the published
issuer stays `http://localhost:8180`. This is why `TF_VAR_keycloak_url` uses
the backchannel URL inside compose but tokens show the frontend URL in `iss`.

The `jwks-server` (nginx) serves the demo L2 client public keys and stands in
for the sandbox's APISIX `/jwks.json` endpoints. For drop-in sandbox use,
override `TF_VAR_placer_l2_jwks_url` / `TF_VAR_fulfiller_l2_jwks_url` with the
APISIX gateway URLs instead.

---

## Bruno

The L2 pre-request scripts use Node.js built-ins (`crypto`, `fs`, `path`).
Bruno's default sandbox is **QuickJS** — these modules do not exist there.

- **CLI:** always pass `--sandbox unsafe`
- **Desktop:** click the green shield (top-right of the collection window) → *Developer mode*

All other requests (L1, validation, negative) work in either sandbox.

---

## Token validator

Environment variables: `ISSUER` (required), `JWKS_URI`, `PORT`, `EXPECTED_AUDIENCE` (optional — per the IG the token `aud` should be the target FHIR API base URL, but Keycloak's default `client_credentials` audience is the realm, so the check is reported but not enforced unless this is set).

`POST /validate` returns a per-check report — useful as a correctness oracle
when developing clients or tweaking the Terraform config. A `warn` does not
fail the request; only `fail` does.

Known inconsistency: `MAX_LIFETIME_SECONDS = 360` in `token-validator/src/validator.ts:27` but the check message says "recommended <= 300s" and the realm is 300 s. Fix constant to 300 or update the message.

---

## Open gaps and action list

From the 2026-06-16 meeting (Trifork pre-sync + call with USZ and Balgrist).
See `aud-design.md` for the full audience claim design analysis.

### Priority order

1. **Fix `.env` in git** — `.env` contains `KEYCLOAK_ADMIN_PASSWORD=admin`, `PLACER_CLIENT_SECRET=placer-secret-2025`, etc. and is tracked by git. Add `.env` to `.gitignore`, create `.env.example` with placeholder values.
2. **Decide audience model** — recommendation is Design 2 (named aud scopes); confirm with UMZH that scope sets are fixed per party type (see `aud-design.md` §7). This is the only outstanding question before implementing.
3. **Implement `aud` claim** — once #2 is decided: add `var.fhir_servers` to `variables.tf`, add `keycloak_openid_client_scope` + `keycloak_openid_audience_protocol_mapper` per FHIR server, assign `aud:*` optional scopes to M2M clients, enable `EXPECTED_AUDIENCE` in `docker-compose.yml`.
4. **Gate L1 clients** — `placer-client` / `fulfiller-client` in `clients.tf` are sandbox/PoC only. Add `enable_sandbox_clients = false` Terraform variable or remove from production config.
5. **Remove `users.tf` and `smart-*` scopes** — `keycloak/terraform/users.tf` is entirely sandbox parity: `web-app` PKCE client with ROPC (`direct_access_grants_enabled = true`) and three demo users with hardcoded passwords. The five `smart-*` scopes in `scopes.tf` are user-facing consent screen scopes, not M2M. Remove or gate behind a flag.
6. **Remove localhost `org_reference` defaults** — `variables.tf:61,67` default to `http://localhost:8084/fhir/Organization/HospitalP` / `…/HospitalF`. These get embedded verbatim in every issued token. Remove defaults to force operators to supply real registry URLs.
7. **Add WARN logging to `FhirContextMapper`** — `FhirContextMapper.java:98` silently swallows parse errors; a client sending malformed `authorization_details` gets a token with no `fhirContext` instead of any error. Log the parse exception at WARN level.
8. **Document onboarding runbook** — what variables a new client requires, what access is needed, who approves. The `m2m_clients` map in `clients.tf` is the natural extension point; Terraform needs to be fully parameterized (no hardcoded localhost defaults) before it can be handed to a non-engineer.
9. **Confirm `tenant` claim with UMZH** — `tenant-mapper` at `clients.tf:193` adds a `tenant` claim (`placer` / `fulfiller`) to every access token. It is a sandbox routing hint, not in the IG spec. Confirm with UMZH whether to retain or drop it.
10. **Production hardening** — `ssl_required = "none"` in `realm.tf:11` (must be `external` or `all`); `start-dev` in `docker-compose.yml:38` (disables all production hardening — document clearly as dev-only).

### Resolved at meeting

- `authorization_details` → `fhirContext` mapping: the current implementation is correct. `FhirContextMapper` reads the raw request parameter and maps it into the AS-signed JWT. The RS reads `fhirContext` from the JWT, not the request. No design change needed.
- L1 / L2 / L3 direction: never allow L1 in production; no upgrade path between levels (new client provisioned at the right level from day one); L3 out of scope.
- Onboarding approach: Terraform, reproducible, VCS-based.

### External / pending

- IP/open-source agreement was pending legal review as of the meeting.
- UMZH GitHub invites not yet done as of the meeting.
- `umzhconnect/umzhconnect-auth` delivery target is still an empty stub.

---

## Audience claim design summary

Full analysis in `aud-design.md`. TL;DR:

| | D1: per-pair client | D2: named aud scopes ✅ | D3: RFC 8707 `resource` |
|---|---|---|---|
| Feasible with KC 26.6.1 | ✅ | ✅ | ❌ (milestoned for KC 26.8.0, experimental) |
| Client count at N orgs | O(N²) | O(N) | O(N) |
| Per-audience scope control | ✅ natural | ⚠️ per-client tuning or D1 exception | ✅ native (when available) |

**Implement D2 now. Track RFC 8707 (`resource` param) for future migration — low-effort swap when KC 26.8.0 ships.**

One open question (§7 of `aud-design.md`): confirm with UMZH that scope sets are fixed per party type. If they are, D2 is a clean fit. If a future requirement needs per-target scope variation, apply D1 selectively for those bilateral pairs on top of D2.
