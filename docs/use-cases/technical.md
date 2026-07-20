# Technical use cases

Use cases relevant to calling hospitals (their applications) and resource
servers (FHIR servers). Covers token acquisition, token validation, and
security/adversarial scenarios under the current architecture: one primary
KC client per hospital ([ADR 0002](../adr/0002-one-client-per-hospital.md)),
constant ecosystem `aud` ([ADR 0003](../adr/0003-constant-ecosystem-audience.md)),
and an optional per-hospital L1 debug client alongside it ([ADR
0004](../adr/0004-reinstate-l1-debug-client.md)) — L1 is for connectivity
debugging only, never a production integration path.

These are the reference behaviors an operator can point a customer at when
debugging integration issues. Most have executable counterparts in the Bruno
collection (`bruno/` — see [ai-docs/bruno.md](../../ai-docs/bruno.md)).

---

## UC-T — Token acquisition (hospital app → AS)

### UC-T1 — Hospital acquires a token (L2)

The standard happy path: any application operated by an onboarded hospital
authenticates with the hospital's shared client identity via `private_key_jwt`
(RFC 7523) and receives an access token.

**Actor:** hospital application
**Precondition:** hospital is onboarded (`config/hospitals/{org_id}.yaml`
exists and Terraform has been applied); the app holds the private key matching
the JWKS published at the registered `jwks_url`.
**Request:**
```http
POST /realms/umzh-connect/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id={org_id}
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=<JWT signed with the hospital's private key>
```
The client assertion must have `iss` = `sub` = `{org_id}` and `aud` = the
realm token endpoint (RFC 7523 §3).

**Expected token (JWT):**

| Where | Claim | Value |
|-------|-------|-------|
| header | `typ` | `at+jwt` (RFC 9068 §2.1) |
| payload | `iss` | realm issuer URL |
| payload | `aud` | **constant ecosystem value** — the realm issuer URL, identical for every hospital and every target ([ADR 0003](../adr/0003-constant-ecosystem-audience.md)) |
| payload | `client_id` | `{org_id}` (RFC 9068 §2.2; hardcoded mapper, distinct from `azp`) |
| payload | `scope` | all `default_scopes` from `config/scopes.yaml` (no `scope` parameter needed) |
| payload | `extensions.umzhconnect.organization_reference` | the hospital's `org_reference` — set by the AS, never by the caller |
| payload | `extensions.umzhconnect.auth_level` | `"L2"` — hardcoded, required on every token ([ADR 0004](../adr/0004-reinstate-l1-debug-client.md)); resource servers use this to distinguish L2 from an L1 debug token ([UC-T8](#uc-t8--debug-client-acquires-an-l1-token), [UC-R6](#uc-r6--rs-enforces-a-minimum-auth_level)) |
| payload | `exp` | now + 300 s |

Bruno: `auth/06-get-placer-token-l2.bru`, `auth/07-get-fulfiller-token-l2.bru`.

---

### UC-T2 — Token with FHIR context

The app declares which FHIR resource it is operating on, and the AS embeds a
`fhirContext` claim in the token.

**Actor:** hospital application
**Additional request parameter (RFC 9396):**
```
authorization_details=[{"type":"umzh-connect-context","identifier":"ServiceRequest/sr-123"}]
```
**Expected additional token claim:**
```json
"fhirContext": [{"reference": "ServiceRequest/sr-123"}]
```
The `FhirContextMapper` reads the raw request parameter directly (not via
Keycloak's `AuthorizationRequestContext`, which is not populated for
`client_credentials` with custom `authorization_details` types on KC 26.x) —
see [ai-docs/mapper.md](../../ai-docs/mapper.md).

Bruno: `auth/05-get-placer-token-context.bru`, `auth/08-get-fulfiller-token-context.bru`.

---

### UC-T3 — Token without `authorization_details`

The app requests a token with no context parameter.

**Expected behavior:** token is issued without a `fhirContext` claim. Absence
of the claim is a valid state, not an error — but context-gated resources will
return 403 to such a token ([UC-R4](#uc-r4--rs-enforces-fhircontext)).

---

### UC-T4 — Requesting optional scopes

The app passes an explicit `scope` parameter naming entries from
`optional_scopes` (e.g. `scope=smart-task-write`).

**Expected behavior:** the requested optional scopes appear in the token in
addition to the defaults. Optional scopes are registered realm-wide — any
onboarded hospital may request any of them; there is no per-hospital grant
(scope-level authorization is a resource-server / future Policy Server
concern).

---

### UC-T5 — Unknown client attempts token acquisition

A caller uses a `client_id` for which no hospital YAML exists (never
onboarded, or offboarded).

**Expected behavior:** Keycloak rejects the request (`invalid_client` /
`unauthorized_client`); no token is issued. This is the zero-implicit-access
guarantee of [ADR 0002](../adr/0002-one-client-per-hospital.md).

---

### UC-T6 — Assertion signed with a rotated key (new `kid`)

After a key rotation, the app signs assertions with the new key; the new `kid`
is published at the registered `jwks_url`.

**Expected behavior:** Keycloak re-fetches the JWKS when it encounters the
unknown `kid`, verifies the assertion, and issues the token — no operator
action. See operational [UC-L1](operational.md#uc-l1--hospital-rotates-its-l2-signing-key)
for the rotation procedure and its pitfalls (reused `kid`, premature old-key
removal).

---

### UC-T7 — Invalid client assertion

The assertion is signed with a key not in the registered JWKS, is expired, or
has the wrong `aud`.

**Expected behavior:** Keycloak rejects with HTTP 400; no token issued.

Bruno: `negative/06-expired-client-assertion.bru`,
`negative/07-wrong-assertion-aud.bru`, `negative/01-wrong-secret.bru`
(`client_secret` presented to an L2 client → 400).

---

### UC-T8 — Debug client acquires an L1 token

**Debug/test use only — not a production integration path.** A hospital that
has requested and been provisioned an L1 debug client
([UC-O5](operational.md#uc-o5--provisioning-an-l1-debug-client), [ADR
0004](../adr/0004-reinstate-l1-debug-client.md)) authenticates with a plain
`client_secret` instead of a signed assertion — useful for isolating
connectivity issues (firewalls, proxies, JWKS reachability) that are harder
to diagnose through L2's signed-assertion flow.

**Actor:** hospital application (debug/test tooling)
**Precondition:** `config/hospitals-l1/{org_id}.yaml` exists and Terraform
has been applied; the hospital holds the Keycloak-generated `client_secret`
for `{org_id}--l1`.
**Request:**
```http
POST /realms/umzh-connect/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id={org_id}--l1
&client_secret=<Keycloak-generated secret>
```

**Expected token (JWT):** same shape as [UC-T1](#uc-t1--hospital-acquires-a-token-l2)
(`organization_reference`, `default_scopes`, ecosystem `aud`), except:

| Where | Claim | Value |
|-------|-------|-------|
| payload | `client_id` | `{org_id}--l1` |
| payload | `extensions.umzhconnect.auth_level` | **`"L1"`** — the signal resource servers use to identify this as a debug token and, if they choose to, reject it for production/clinical data flows ([UC-R6](#uc-r6--rs-enforces-a-minimum-auth_level)) |

`authorization_details` (FHIR context, [UC-T2](#uc-t2--token-with-fhir-context))
works identically on the L1 client — the mapper set is the same as L2's.

**Expected behavior when no L1 file exists for the hospital:** same as
[UC-T5](#uc-t5--unknown-client-attempts-token-acquisition) —
`invalid_client`, no token issued. Having an L2 client does not imply an L1
client exists, and vice versa.

---

## UC-R — Token use at the resource server

### UC-R1 — RS validates signature and standard claims

The FHIR server verifies the JWT signature against the AS's published JWKS
(`/realms/umzh-connect/protocol/openid-connect/certs`) and checks `iss` and
`exp`. Expired or tampered tokens → HTTP 401.

---

### UC-R2 — RS checks `aud` — and what that does *not* give you

The RS verifies `aud` equals the constant ecosystem value (the realm issuer
URL).

**Important:** under [ADR 0003](../adr/0003-constant-ecosystem-audience.md)
this check only proves the token was issued for the umzh-connect ecosystem.
It does **not** bind the token to a specific FHIR server — every valid token
carries the same `aud`, so a token obtained for use at server A is
structurally acceptable at server B. Cross-server isolation is deliberately
not provided by the AS at this stage; each FHIR server (and later the Policy
Server) must authorize per calling organization
([UC-R5](#uc-r5--rs-reads-organization_reference-for-consent-lookup)).

---

### UC-R3 — RS enforces SMART scope

The RS checks the token's `scope` claim contains the scope required for the
operation (e.g. `system/Patient.r` for `GET /fhir/Patient/:id`). Insufficient
scope → HTTP 403.

Note the limits: since every hospital client carries the same
`default_scopes`, the scope claim distinguishes *operations*, not *callers*.
Caller-level authorization is UC-R5.

---

### UC-R4 — RS enforces `fhirContext`

Context-gate enforcement: access to a specific FHIR resource is allowed only
if that resource (or an ancestor in its reference graph) appears in the
token's `fhirContext`.

**Example:** `GET /fhir/ServiceRequest/sr-123` requires
`ServiceRequest/sr-123` in `fhirContext`; a token without it → HTTP 403 even
with sufficient scope.

Bruno: `negative/04-context-gate-without-context.bru`; the mock
implementation lives in `token-validator/`.

---

### UC-R5 — RS reads `organization_reference` for consent lookup

The RS extracts `extensions.umzhconnect.organization_reference` to identify
the calling organization, then checks its own authorization (e.g. an active
FHIR `Consent` for that org). No authorization → HTTP 403.

This claim is trustworthy for that purpose because it is hardcoded per client
by the AS from the hospital's registered `org_reference` — a caller cannot
influence it. Under the current architecture it is the **primary caller-identity
signal** for resource servers (together with `client_id`), since neither `aud`
nor `scope` differentiates callers.

---

### UC-R6 — RS enforces a minimum `auth_level`

The RS reads `extensions.umzhconnect.auth_level` (`"L1"` or `"L2"`,
[ADR 0004](../adr/0004-reinstate-l1-debug-client.md)) and rejects tokens
below whatever minimum it requires for the operation being performed.

**Why this matters:** L1 (`client_secret`) is provisioned only as an
explicit, per-hospital **debug client** for connectivity troubleshooting
([UC-O5](operational.md#uc-o5--provisioning-an-l1-debug-client),
[UC-T8](#uc-t8--debug-client-acquires-an-l1-token)) — it is never a
production integration path, and its client secret gets lighter-weight
handling than a real production credential (see ADR 0004's "Relaxed secret
handling" decision). A resource server that treats an L1 token as equivalent
to L2 for real clinical data flows defeats the point of that separation.

**Expected behavior:** an RS that only serves production/clinical data
should require `auth_level = "L2"` and reject `"L1"` tokens (HTTP 403) even
if signature, `aud`, `scope`, and `fhirContext` all check out. An RS that
deliberately supports debug/test traffic may accept `"L1"`, but should not
treat it as interchangeable with a real integration without a documented
reason.

**Current state:** the AS stamps the claim on every token; it does not
enforce a minimum itself — enforcement is each resource server's
responsibility (and, per ADR 0004's "Revisit when", a candidate for
centralization once a Policy Server exists). Since the claim is required and
never absent ([ADR 0004](../adr/0004-reinstate-l1-debug-client.md)
supersedes [ADR 0001](../adr/0001-defer-auth-level-claim.md)'s deferral), an
RS has no "claim missing → assume L2" case to reason about — every token
carries an explicit value.

---

## UC-S — Security and adversarial scenarios

### UC-S1 — Cross-server token replay

A valid token obtained by hospital A for use at server B is replayed at
server C.

**Current state — accepted risk:** the constant ecosystem `aud` does *not*
prevent this; the token verifies successfully at server C. This is a knowing
consequence of [ADR 0003](../adr/0003-constant-ecosystem-audience.md) (same
risk profile as the original 2026-06-23 deferral). Mitigation is pushed to the
resource servers: server C must authorize hospital A via
`organization_reference` / consent ([UC-R5](#uc-r5--rs-reads-organization_reference-for-consent-lookup))
before serving anything. Target-specific `aud` binding (RFC 8707) is the
revisit path once Keycloak's support leaves experimental status.

---

### UC-S2 — Client asserts a `client_id` it does not own

An attacker presents a `client_assertion` whose `iss`/`sub` name a different
hospital's `client_id`, or signs with a key not in that hospital's JWKS.

**Expected behavior:** Keycloak validates that the assertion's `iss` and `sub`
match the request's `client_id` and that the signature verifies against that
client's registered JWKS. Mismatch → rejected. One hospital cannot mint tokens
carrying another hospital's `organization_reference`.

---

### UC-S3 — Malformed `authorization_details`

A client sends syntactically invalid `authorization_details`, or an unknown
`type`.

**Current behavior:** the `FhirContextMapper` ignores it and issues a token
**without** `fhirContext` — no error is returned, and parse failures are
swallowed silently (open gap: `FhirContextMapper` should log at WARN — see
[ai-docs/open-gaps.md](../../ai-docs/open-gaps.md) #2). Operationally: a
customer reporting "my token has no fhirContext" most likely has a malformed
or mistyped `authorization_details` parameter — the type must be exactly
`umzh-connect-context`.

Bruno: `negative/08-unknown-context-type.bru`.

---

### UC-S4 — Forged or tampered token presented to the RS

An attacker modifies a valid token's payload or fabricates one without the
AS's private key.

**Expected behavior:** the RS's signature check against the AS JWKS fails →
HTTP 401, regardless of claim content.

Bruno: `negative/02-validate-garbage-token.bru`.

---

### UC-S5 — Unsupported grant types

The IG model is M2M only. Interactive grants (`authorization_code`, etc.) are
rejected for the hospital M2M clients. `client_secret` authentication is
rejected on the primary L2 client (`negative/01-wrong-secret.bru` presents
one to an L2 client → 400) — it's only valid against a hospital's opt-in L1
debug client, if one has been provisioned
([UC-T8](#uc-t8--debug-client-acquires-an-l1-token)).

Bruno: `negative/09-unsupported-grant-type.bru`, `negative/01-wrong-secret.bru`.

(The `web-app` PKCE client and demo users in the sandbox config are dev-only
and must be removed/gated for production — see
[ai-docs/realm-contract.md](../../ai-docs/realm-contract.md).)
