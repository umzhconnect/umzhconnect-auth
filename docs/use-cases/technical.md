# Technical use cases

Use cases relevant to calling applications and resource servers. Covers token
acquisition, token validation, and security/adversarial scenarios.

---

## UC-T — Token acquisition (calling app → AS)

### UC-T1 — App acquires token for a specific FHIR server (L2)

The standard happy-path: a calling app uses `private_key_jwt` to authenticate
and receives an access token scoped to a single target FHIR server.

**Actor:** calling app  
**Precondition:** KC client `{org_id}--{app_id}--{server_key}` exists (grant
in place + `terraform apply` done); app holds the private key matching the
registered JWKS.  
**Request:**
```http
POST /realms/umzh-connect/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id={org_id}--{app_id}--{server_key}
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=<JWT signed with app private key>
&scope=system/Patient.r system/ServiceRequest.r
```
**Expected token claims:**
- `iss` = realm issuer URL
- `aud` = target FHIR server base URL
- `scope` = granted intersection of requested scopes
- `extensions.umzhconnect.organization_reference` = org's canonical FHIR URL
- `exp` = now + 300 s

---

### UC-T2 — App acquires token with FHIR context

App declares which specific FHIR resource it is operating in context of, causing
the AS to embed a `fhirContext` claim in the issued token.

**Actor:** calling app  
**Additional request parameter:**
```
authorization_details=[{"type":"umzh-connect-context","identifier":"ServiceRequest/sr-123"}]
```
**Expected additional token claim:**
```json
"fhirContext": [{"reference": "ServiceRequest/sr-123"}]
```
**Note:** the `FhirContextMapper` reads the raw request parameter directly
(not via `AuthorizationRequestContext`) because Keycloak 26.x does not populate
that API for the `client_credentials` flow with custom `authorization_details`
types.

---

### UC-T3 — App requests a subset of its granted scopes

App requests fewer scopes than the grant permits, for least-privilege operation.

**Actor:** calling app  
**Expected behavior:** AS issues a token with exactly the requested scopes (not
the full grant). The narrower scope set must be reflected in the `scope` claim.

---

### UC-T4 — App requests scopes exceeding its grant

App requests a scope that is not in its grant for the target FHIR server.

**Actor:** calling app  
**Expected behavior:** to be confirmed — two plausible behaviors:
- AS rejects the request with `invalid_scope`.
- AS silently trims to the granted set and issues the token.

**Open question:** which behavior does Keycloak 26.x apply, and which does the
IG require?

---

### UC-T5 — App with no grant attempts token acquisition

App tries to authenticate using a `client_id` that does not exist in Keycloak
(no grant entry was created for this app/server pair).

**Actor:** calling app  
**Expected behavior:** Keycloak returns `unauthorized_client` or equivalent; no
token is issued.

---

### UC-T6 — App signs assertion with a rotated key (new `kid`)

After a key rotation (see UC-L1), the app begins signing assertions with the new
key. The old `kid` is no longer present in the JWKS.

**Actor:** calling app  
**Expected behavior:** Keycloak re-fetches the JWKS from the registered
`jwks_url`, finds the new `kid`, verifies the assertion, and issues the token
without any operator intervention.

**Open question:** Keycloak's JWKS cache TTL — is there a window during which
re-fetch does not happen and assertions with the new `kid` are incorrectly
rejected?

---

### UC-T7 — App signs assertion with a wrong or revoked key

App presents a client assertion signed with a key whose `kid` is not in the
registered JWKS, or whose signature does not verify.

**Actor:** calling app (or attacker)  
**Expected behavior:** Keycloak rejects the assertion; no token is issued.

---

### UC-T8 — Token requested without `authorization_details`

App acquires a token for a resource-level operation that does not require a
specific FHIR context (e.g. a broad read, not a context-scoped operation).

**Actor:** calling app  
**Expected behavior:** token is issued without a `fhirContext` claim. Absence of
the claim is a valid state, not an error.

---

## UC-R — Token use at the resource server

### UC-R1 — RS validates signature and standard claims

Resource server verifies the token's JWT signature against Keycloak's published
JWKS, and checks `iss`, `exp`, and `iat`.

**Actor:** resource server  
**Expected behavior:** valid token accepted; expired or tampered token rejected.

---

### UC-R2 — RS enforces audience

Resource server rejects tokens whose `aud` does not match its own FHIR base URL.

**Actor:** resource server  
**Expected behavior:** token presented to the wrong FHIR server (correct
signature, wrong `aud`) is rejected with HTTP 401. This prevents cross-server
token replay.

---

### UC-R3 — RS enforces SMART scope

Resource server checks that the token's `scope` claim includes the scope required
for the requested operation (e.g. `system/Patient.r` for `GET /fhir/Patient/:id`).

**Actor:** resource server  
**Expected behavior:** insufficient scope → HTTP 403.

---

### UC-R4 — RS uses `fhirContext` for fine-grained access control

Resource server applies context-gate enforcement: a request to a specific FHIR
resource is only allowed if that resource (or an ancestor in its reference graph)
appears in the token's `fhirContext`.

**Actor:** resource server  
**Example:** `GET /fhir/ServiceRequest/sr-123` is allowed only if
`ServiceRequest/sr-123` is present in `fhirContext`.  
**Expected behavior:** token without a matching `fhirContext` entry → HTTP 403,
even if scope is sufficient.

---

### UC-R5 — RS reads `organization_reference` for consent lookup

Resource server extracts `extensions.umzhconnect.organization_reference` from
the token to identify the calling organization, then looks up the active FHIR
`Consent` resource authorizing that org to access the requested data.

**Actor:** resource server / OPA policy engine  
**Expected behavior:** no active Consent for the org → HTTP 403.

---

### UC-R6 — Token replayed at wrong FHIR server

A valid token issued for FHIR server A is presented to FHIR server B.

**Actor:** attacker / misconfigured client  
**Expected behavior:** RS B rejects the token because `aud` ≠ its own URL
(UC-R2 applied). The token's validity at server A is irrelevant.

---

### UC-R7 — Expired token presented

A token past its `exp` timestamp is presented to the resource server.

**Actor:** calling app (retry after long delay) or attacker  
**Expected behavior:** RS rejects with HTTP 401. Token lifetime is 300 s.

---

## UC-S — Security and adversarial scenarios

### UC-S1 — Cross-server token replay

Identical to UC-R6 — covered by `aud` enforcement at the resource server. Noted
separately to emphasize it as an explicit threat the AS design must prevent.

**Mitigation:** D1 architecture issues one KC client per (app, FHIR server),
each with a distinct `aud` scope. A token acquired for server A carries
`aud = url-of-server-A` and is structurally invalid at any other server.

---

### UC-S2 — Client asserts a `client_id` it does not own

Attacker or misconfigured app presents a `client_assertion` claiming to be a
different `client_id`.

**Expected behavior:** Keycloak validates that the assertion's `iss` and `sub`
claims match the `client_id` in the token request. Mismatch → request rejected.

---

### UC-S3 — Malformed `authorization_details` in token request

Client sends a syntactically invalid or semantically incorrect
`authorization_details` value.

**Expected behavior:** should produce a clear error response. Currently the
`FhirContextMapper` silently swallows parse errors — a client sending malformed
`authorization_details` receives a token with no `fhirContext` instead of an
error (open gap — `FhirContextMapper.java:98` needs WARN-level logging and
ideally an error response).

---

### UC-S4 — Client requests scopes not in the FHIR server's grant

See UC-T4. Recorded here as a security scenario: scope over-request must not
allow a client to escalate beyond its provisioned grant, regardless of whether
Keycloak trims or rejects.

**Requirement:** the issued token must never contain a scope that is not in the
client's grant for that FHIR server.

---

### UC-S5 — Forged or tampered token presented to RS

Attacker modifies a valid token payload or fabricates a token without the AS
private key.

**Expected behavior:** RS verifies the JWT signature against Keycloak's published
JWKS; signature mismatch → HTTP 401. The token is structurally invalid regardless
of claim content.
