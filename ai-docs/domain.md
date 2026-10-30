---
recap: "FHIR/SMART on FHIR domain context — resources, system scopes, Backend Services auth, and the cross-org referral flow."
keywords: [FHIR, SMART on FHIR, system scopes, backend services, private_key_jwt, authorization_details, http://fhir.ch/ig/ch-umzh-connect/context, context-gated, counter-party entitlement, referral flow, Placer, Fulfiller, ServiceRequest, Task, Consent, organization_reference, OPA, Consent.status, meaning=related]
---

# Domain context

## UMZH Connect

A standardized API ecosystem for sharing clinical data between healthcare organizations. Initial use case: cross-organizational referral workflows (orthopedic surgery, sarcoma tumor boards) between a **Placer** (referring party) and a **Fulfiller** (receiving party).

Governed by the FHIR IG at `https://build.fhir.org/ig/umzhconnect/umzhconnect-ig/`. The normative security spec lives in `~/github/umzhconnect/umzhconnect-ig/input/pagecontent/security.md` and `security-implementation.md` — read those before making auth decisions.

## FHIR basics

- Everything is a **Resource**: Patient, Condition, ServiceRequest, Task, Consent, etc.
- Resources exposed via RESTful HTTP API and reference each other to form a graph.
- An **Implementation Guide (IG)** constrains FHIR for a specific use case.
- Placer hosts a FHIR server with `ServiceRequest` resources; Fulfiller hosts one with `Task` resources.

## SMART on FHIR

**System scopes** — standardized permission language: `system/<ResourceType>.<action>` (e.g. `system/Patient.rs`, `system/Task.crus`). The `system/` prefix means M2M — no user logged in.

**Backend Services** — instead of a client secret, clients authenticate with `private_key_jwt` signed with their private key, validated against registered JWKS. No shared secrets at Level 2.

**Context (RFC 9396 `authorization_details`)** — the client names the workflow root it is operating in (`ServiceRequest/{id}` on the Placer, `Task/{id}` on the Fulfiller). The AS returns it in the token response and as a top-level `authorization_details` claim (via `ContextMapper`, see [mapper.md](mapper.md)). A token carries at most one context. The RS requires exactly one for every resource type except `Task` and `Questionnaire`, checks the caller against its own record of the counter-party, and limits the read to the root's context graph.

## The referral flow

```
Fulfiller → Keycloak:
  POST /token
  grant_type=client_credentials
  scope=system/ServiceRequest.rs system/Patient.rs
  authorization_details=[{"type":"http://fhir.ch/ig/ch-umzh-connect/context","identifier":"ServiceRequest/sr-123"}]
  client_assertion=<JWT signed with Fulfiller's private key>

Keycloak issues access token:
  {
    "iss": "https://auth.umzhconnect.ch",
    "aud": "https://fhir.placer.example",    ← target FHIR server URL
    "scope": "system/ServiceRequest.rs system/Patient.rs",
    "extensions": { "umzhconnect": { "organization_reference": "..." } },
    "authorization_details": [{ "type": "http://fhir.ch/ig/ch-umzh-connect/context", "identifier": "ServiceRequest/sr-123" }]
  }

Fulfiller → Placer's FHIR server:
  GET /ServiceRequest/sr-123
  Authorization: Bearer <access token>

Placer's policy engine (OPA):
  1. Validate JWT signature and scope
  2. Check organization_reference against the counter-party recorded for ServiceRequest/sr-123
     (ServiceRequest.performer or an active Consent)
  3. Verify requested resource is within the reference graph of sr-123
  → Allow or deny
```

Context enforcement uses FHIR `Consent` resources (`meaning = "related"` covers the root resource and its transitive references). Revoke by setting `Consent.status = inactive`.

## Full sandbox stack

Keycloak 26.6.1, HAPI FHIR, APISIX (API gateway), OPA (fine-grained authz), nginx, PostgreSQL.

## Reference repos

| Repo | Role |
|------|------|
| `~/github/umzhconnect/umzhconnect-ig` | Normative security spec |
| `~/github/umzhconnect/umzhconnect-sandbox` | Running reference implementation |
| `~/github/umzhconnect/umzhconnect-auth` | Empty skeleton — this repo fills it |
