# CLAUDE.md — Instructions for Claude Code

## Project purpose

Keycloak-based OAuth 2.0 Authorization Server for the UMZH Connect ecosystem,
implementing the IG's machine-to-machine security model. Three deliverables:

| Folder | What | Production? |
|--------|------|-------------|
| `keycloak/` | Custom Keycloak image + Terraform realm config | Yes (image + config) |
| `token-validator/` | Mock resource server that validates tokens | No — dev/test only |
| `bruno/` | Request collection (auth, validation, negative cases) | No |

## Reference repos (cloned at ~/github/umzhconnect/)

| Repo | Role |
|------|------|
| `umzhconnect-ig` | Normative security spec — read `input/pagecontent/security.md` and `security-implementation.md` before making auth decisions |
| `umzhconnect-sandbox` | Running reference implementation; the Keycloak realm contract in this repo must be a drop-in replacement for the sandbox's `keycloak` service |
| `umzhconnect-auth` | Empty skeleton — this repo is what fills it |

## Auth model (IG summary)

- Pure M2M: `client_credentials` grant, no user flows, no `openid` scope.
- **Level 1** (`client_secret`) — sandbox/PoC only.
- **Level 2** (`private_key_jwt`, JWKS registered at onboarding) — production baseline. Level 3 (mTLS/DPoP) is out of scope.
- RFC 9396 `authorization_details` of type `umzh-connect-context` → mapped by the custom `FhirContextMapper` into a `fhirContext` claim.
- Every token carries `extensions.umzhconnect.organization_reference` (set by the AS from the onboarding record, never by the client).
- SMART system scopes: `system/<Resource>.<cruds>`.

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

## docker-compose

`KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` lets in-network services (Terraform,
token-validator) reach Keycloak at `http://keycloak:8080` while the published
issuer stays `http://localhost:8180`. This is why `TF_VAR_keycloak_url` uses
the backchannel URL inside compose but tokens show the frontend URL in `iss`.

The `jwks-server` (nginx) serves the demo L2 client public keys and stands in
for the sandbox's APISIX `/jwks.json` endpoints. For drop-in sandbox use,
override `TF_VAR_placer_l2_jwks_url` / `TF_VAR_fulfiller_l2_jwks_url` with the
APISIX gateway URLs instead.

## Bruno

The L2 pre-request scripts use Node.js built-ins (`crypto`, `fs`, `path`).
Bruno's default sandbox is **QuickJS** — these modules do not exist there.

- **CLI:** always pass `--sandbox unsafe`
- **Desktop:** click the green shield (top-right of the collection window) → *Developer mode*

All other requests (L1, validation, negative) work in either sandbox.

## Token validator

Environment variables: `ISSUER` (required), `JWKS_URI`, `PORT`, `EXPECTED_AUDIENCE` (optional — per the IG the token `aud` should be the target FHIR API base URL, but Keycloak's default `client_credentials` audience is the realm, so the check is reported but not enforced unless this is set).

`POST /validate` returns a per-check report — useful as a correctness oracle
when developing clients or tweaking the Terraform config. A `warn` does not
fail the request; only `fail` does.
