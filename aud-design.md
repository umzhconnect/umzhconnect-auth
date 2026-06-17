# Audience (`aud`) claim — design analysis

**Date:** 2026-06-16  
**Author:** Trifork  
**Status:** Recommendation ready — decision needed on scope-per-target question (see §6)

---

## 1. TL;DR

| | Today | Recommended (D2) | Future (D3) |
|---|---|---|---|
| `aud` claim | ❌ set to `client_id`, not FHIR URL | ✅ set to FHIR server base URL | ✅ same, via standard `resource` param |
| Client count at N orgs | — | O(N) | O(N) |
| Extra token round-trips | — | Zero | Zero |
| Feasible now? | — | ✅ Yes, fully supported | ❌ No — KC 26.8.0 at earliest, lands as experimental |

**Recommendation: implement Design 2 (named audience scopes) now. Design 3 (RFC 8707 `resource` parameter) is not available in KC 26.6.1 and will land as experimental in a future release — track and reassess.**

---

## 2. Current state and why it matters

Today, Keycloak issues tokens where `aud` = the client ID (e.g. `fulfiller-client-l2`). The IG requires `aud` = the target FHIR server base URL (e.g. `https://fhir.placer.example`).

This matters because the `aud` claim is the resource server's proof that a token was issued *for it specifically*. RFC 7519 §4.1.3 requires the RS to reject tokens where `aud` does not include its own URL. Without a correct `aud`:

- A token obtained to access HospitalP's FHIR server can be replayed at HospitalF's — the only defence left is the `fhirContext` + Consent check, which is authorization, not authentication of the token recipient.
- Any resource server implementing strict audience validation (as it should) will reject these tokens outright.

The token validator already has `EXPECTED_AUDIENCE` wired but disabled (`docker-compose.yml`) because nothing sets the right value yet.

**Important:** because the existing design already forces one token per workflow interaction (the client includes one `authorization_details` context per token request), fixing `aud` adds **zero extra token round-trips** — it is one additional parameter in the same request.

---

## 3. Deployment topology assumption

The IG token example shows:
```json
{ "iss": "https://auth.umzhconnect.ch", "aud": "https://fhir.placer.example" }
```
One network-level issuer, multiple party-specific FHIR servers as distinct audiences. This, combined with the sandbox having both placer and fulfiller clients in one Keycloak realm, and the meeting discussion of "one client, multiple audiences for scalability" and "resource param in client_credentials," points to a **single shared AS serving N party FHIR servers**.

If the actual deployment is one AS per party (each org runs their own Keycloak), the problem collapses: add one realm-level audience mapper pointing to that party's own FHIR server URL. Everything below covers the harder, more likely shared-AS case.

---

## 4. Use cases

| # | Scenario | What audience is needed |
|---|----------|------------------------|
| **U1** | Fulfiller fetches ServiceRequest + referenced resources from Placer's FHIR server | `aud = https://fhir.placer.example` |
| **U2** | Placer reads Task status and output resources from Fulfiller's FHIR server | `aud = https://fhir.fulfiller.example` |
| **U3** | Third org joins network; needs tokens for both existing FHIR servers | Two possible audiences, same client |
| **U4** | One org has two FHIR servers (lab, radiology) at different base URLs | Multiple audiences per calling client |
| **U5** | HospitalF grants HospitalG only `system/Patient.r` but HospitalH gets `system/Patient.r system/Task.cru` | Per-audience scope restriction |
| **U6** | Key rotation, offboarding a partner org | Change config for one party without touching others |

U1 and U2 are in scope today. U3 is the first realistic scale step. U4 and U5 are where designs diverge.

---

## 5. The three candidate designs

### Design 1 — One client per (caller, target) pair · Static per-client audience

Each organization registers one Keycloak client *per target FHIR server* it needs to call: `fulfiller-to-placer`, `placer-to-fulfiller`, `hospitalC-to-placer`, etc. Each client has an audience mapper hardcoded to its target.

```hcl
resource "keycloak_openid_audience_protocol_mapper" "aud" {
  client_id                = keycloak_openid_client.m2m["fulfiller-to-placer"].id
  name                     = "audience-mapper"
  included_custom_audience = "https://fhir.placer.example"
  add_to_id_token          = false
  add_to_access_token      = true
}
```

Token request (unchanged from today — no new parameters):
```
POST /token
grant_type=client_credentials
client_id=fulfiller-to-placer
scope=system/ServiceRequest.rs
authorization_details=[{"type":"umzh-connect-context","identifier":"ServiceRequest/sr-123"}]
```

**Use case coverage:**
- U1/U2: Natural fit.
- U3: Operator creates N new clients — one per existing FHIR server. At 10 orgs: ~90 clients.
- U4: Adds another client per extra FHIR server. Multiplies further.
- U5: ✅ Clean — different clients simply have different scope sets.
- U6: Disable/delete one client. Surgical.

---

### Design 2 — One client per org · Named audience scopes ✅ Recommended

One Keycloak client per organization. One Keycloak client scope per target FHIR server in the network, each carrying an audience mapper. A client's optional scope list acts as its audience allow-list.

```hcl
# One scope per FHIR server — defined once, shared across all clients
resource "keycloak_openid_client_scope" "fhir_audience" {
  for_each = var.fhir_servers   # map of { "fhir-placer" = "https://fhir.placer.example", ... }
  realm_id = keycloak_realm.umzh_connect.id
  name     = "aud:${each.key}"
}

resource "keycloak_openid_audience_protocol_mapper" "fhir_audience" {
  for_each                 = var.fhir_servers
  realm_id                 = keycloak_realm.umzh_connect.id
  client_scope_id          = keycloak_openid_client_scope.fhir_audience[each.key].id
  name                     = "audience-mapper"
  included_custom_audience = each.value   # the FHIR server URL goes into aud
  add_to_id_token          = false
  add_to_access_token      = true
}

# Per client: which audiences is it allowed to request?
resource "keycloak_openid_client_optional_scopes" "aud_allowlist" {
  realm_id        = keycloak_realm.umzh_connect.id
  client_id       = keycloak_openid_client.m2m["fulfiller-l2"].id
  optional_scopes = ["aud:fhir-placer"]   # operator-controlled allow-list
}
```

Token request (client adds the `aud:*` scope name for its target):
```
POST /token
grant_type=client_credentials
client_id=fulfiller-l2
scope=system/ServiceRequest.rs aud:fhir-placer
authorization_details=[{"type":"umzh-connect-context","identifier":"ServiceRequest/sr-123"}]
```

Issued token:
```json
{
  "iss": "https://auth.umzhconnect.ch",
  "aud": "https://fhir.placer.example",
  "scope": "system/ServiceRequest.rs aud:fhir-placer",
  "extensions": { "umzhconnect": { "organization_reference": "..." } },
  "fhirContext": [{ "reference": "ServiceRequest/sr-123" }]
}
```

**Use case coverage:**
- U1/U2: Client requests `aud:fhir-placer` or `aud:fhir-fulfiller` as appropriate.
- U3: Add one `aud:fhir-hospitalC` scope; add it to the new org's client optional scope list.
- U4: Add two `aud:*` scopes; assign both as optional scopes to the calling client.
- U5: ⚠️ Not directly solved. Scope sets are per client, not per (client × audience) pair. If HospitalF needs different scopes for different targets, it requires either a custom scope set per client (manageable at small N) or a separate client per high-trust bilateral pair (D1 applied selectively).
- U6: Remove scope from the client's optional list to revoke. One Terraform change.

**Why the scope name appears in the token:** `aud:fhir-placer` will appear in the `scope` claim alongside the SMART scopes. This is the only cosmetic downside of D2 — the scope name is a configuration artifact, not a functional permission. Resource servers should ignore it.

---

### Design 3 — One client per org · RFC 8707 `resource` parameter ❌ Not available yet

> **Verdict: NOT feasible with KC 26.6.1. The feature does not exist in this version.**

This would be the cleanest design: the client specifies the target FHIR URL directly in the token request using the standard `resource` parameter, and the AS sets `aud` to that URL without needing named scopes.

```
POST /token
grant_type=client_credentials
client_id=fulfiller-l2
scope=system/ServiceRequest.rs
resource=https://fhir.placer.example
authorization_details=[...]
```

**Why it is blocked:**

RFC 8707 Resource Indicators support in Keycloak is tracked as [keycloak/keycloak#14355](https://github.com/keycloak/keycloak/issues/14355). As of 2026-06-16:

- The feature is milestoned for **KC 26.8.0**, which has not been released (latest is 26.6.3).
- A community implementation PR (#35711) was closed with changes requested; the KC core team is rebuilding it from scratch under 15 sub-tasks, only 4 of which are complete.
- The roadmap is: **experimental** in 26.8.0 → **preview** in a later 26.x release → stable (no date).
- The Terraform provider has no support for it either.

The KC team's own issue description explicitly acknowledges that the scope-based approach (Design 2) is the current workaround: *"A client can obtain tokens with different `aud` values based on what `scope` parameters are included in the request."* They note the limitation (non-standard selection mechanism, scope names instead of resource URIs) — which is precisely why they are adding RFC 8707.

**How it would handle U1–U6 (when available):**
- U1/U2: Natural — just add `resource=<url>` to the existing token request.
- U3: Add org to the new client's allowed-resources list. O(N) clients.
- U4: Zero config — client requests `resource=<url>` per call, no new scope to assign.
- U5: KC resource indicators support scope filtering per resource — potentially cleanest solution, but requires deeper per-resource configuration.
- U6: Remove from allow-list. One config change.

---

## 6. Comparison

| Dimension | D1: Per-pair client | D2: Named aud scopes ✅ | D3: RFC 8707 `resource` |
|-----------|--------------------|-----------------------|------------------------|
| **FHIR / IG conformance** | ✅ `aud` = FHIR URL | ✅ `aud` = FHIR URL | ✅ `aud` = FHIR URL |
| **Current state** | Fix required | Fix required | Fix required |
| **Feasible with KC 26.6.1** | ✅ Yes | ✅ Yes | ❌ No |
| **Terraform support** | `keycloak_openid_audience_protocol_mapper` — fully supported | Same, on scopes — fully supported | Not available |
| **Client developer experience** | Simple — no new params | Must know scope name per target | Clean — just add `resource=<url>` |
| **Token round-trips vs. today** | Zero extra | Zero extra | Zero extra |
| **Onboarding a new org** | Create N clients (one per existing FHIR server) | Create 1 client + assign scope(s) | Create 1 client + configure allow-list |
| **Client count at N orgs** | O(N²) | O(N) | O(N) |
| **Scope count** | O(N) per client | O(N) shared scopes | O(N) per client (for allow-list) |
| **Offboarding / revoke** | Disable one client | Remove scope assignment | Remove from allow-list |
| **Key rotation** | Per bilateral client | Per org client — one rotation, all audiences | Same as D2 |
| **Per-audience scope control (U5)** | ✅ Natural | ⚠️ Requires per-client tuning or D1 exception | ✅ Native (when available) |
| **Multiple FHIR servers per org (U4)** | Multiplies client count | Add one scope assignment per server | Zero config |
| **Audit / maintainability** | Hard at scale (O(N²) TF resources) | Clear — scope names make intent visible | Compact; audience policy less visible at rest |
| **Migration from D2 to D3** | — | Low effort — same scope structure, swap selector mechanism | — |

---

## 7. Open question before implementing

**Does the UMZH network need per-target scope variation (U5)?**

In the current model, scope sets are fixed per party type: all placers share the same placer scopes; all fulfillers share the fulfiller scopes. If this holds, U5 does not arise, and Design 2 is a clean fit.

If a future requirement emerges where an org grants a different scope set to different counter-parties (e.g. a restricted partner that may only read `system/Task.r` while a full partner gets `system/Task.cru`), the right answer is a small number of purpose-specific bilateral clients (D1 applied selectively), not restructuring the whole audience design.

**Action: confirm with UMZH that scope sets are fixed per party type.**

---

## 8. Recommendation and migration path

### Implement now: Design 2

1. Add `var.fhir_servers` to `variables.tf` — a map of `{ scope-name → FHIR server URL }`, no defaults (operators must supply real URLs).
2. Add `keycloak_openid_client_scope` + `keycloak_openid_audience_protocol_mapper` for each entry.
3. Add the relevant `aud:*` scope to each M2M client's optional scope list.
4. Enable `EXPECTED_AUDIENCE` in `docker-compose.yml` once the mapper is in place and test with the token validator.

The proof-of-concept Terraform is in §5 (Design 2). The Bruno collection needs one new scope parameter in the L2 token requests.

### Track for future: Design 3

Watch [keycloak/keycloak#47117](https://github.com/keycloak/keycloak/issues/47117) (experimental) and [#47118](https://github.com/keycloak/keycloak/issues/47118) (preview). When the feature reaches preview status and the Terraform provider exposes it, Design 3 is a low-effort migration from Design 2: the audience scopes become the per-client resource allow-list, and the client switches from requesting `aud:fhir-placer` as a scope to sending `resource=https://fhir.placer.example` as a parameter.

### Do not use: Design 1 as the default

Only apply D1 for the specific case where two orgs need genuinely different scope grants (U5). Even then, keep it as an exception on top of D2, not a replacement.
