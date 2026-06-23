---
recap: "FHIR/SMART on FHIR domain context — resources, system scopes, Backend Services auth, and the cross-org referral flow."
keywords: [FHIR, SMART on FHIR, system scopes, backend services, private_key_jwt, fhirContext, authorization_details, umzh-connect-context, referral flow, Placer, Fulfiller, ServiceRequest, Task, Consent, organization_reference, OPA, Consent.status, meaning=related]
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

**System scopes** — standardized permission language: `system/<ResourceType>.<action>` (e.g. `system/Patient.r`, `system/Task.cru`). The `system/` prefix means M2M — no user logged in.

**Backend Services** — instead of a client secret, clients authenticate with `private_key_jwt` signed with their private key, validated against registered JWKS. No shared secrets at Level 2.

**fhirContext** — client declares which FHIR resource it's operating in context of; the AS maps this (via `FhirContextMapper`) into a `fhirContext` claim in the issued JWT. The RS uses this for fine-grained authorization.

## The referral flow

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
    "aud": "https://fhir.placer.example",    ← target FHIR server URL
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

## Full sandbox stack

Keycloak 26.6.1, HAPI FHIR, APISIX (API gateway), OPA (fine-grained authz), nginx, PostgreSQL.

## Reference repos

| Repo | Role |
|------|------|
| `~/github/umzhconnect/umzhconnect-ig` | Normative security spec |
| `~/github/umzhconnect/umzhconnect-sandbox` | Running reference implementation |
| `~/github/umzhconnect/umzhconnect-auth` | Empty skeleton — this repo fills it |
