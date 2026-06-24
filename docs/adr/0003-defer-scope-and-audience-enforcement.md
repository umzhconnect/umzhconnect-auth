# 0003 — Defer scope and audience enforcement to downstream

**Status:** Accepted  
**Date:** 2026-06-23  
**Authors:** Trifork

---

## Context

OAuth 2.0 allows the Authorization Server to enforce which scopes a client may use and to bind tokens to a specific audience (`aud` = target resource server URL, per RFC 7519 §4.1.3). Without audience binding, a token issued for one FHIR server can be presented at another.

These enforcement mechanisms require the AS to know, at token-issuance time, which FHIR server is being targeted and which scopes apply to that call. This knowledge must be provisioned per (caller, target) pair.

USZ and Balgrist (UMZH) confirmed in the 2026-06-23 meeting that neither scope nor audience enforcement should be applied at the AS level at this stage. Their reasoning:

- FHIR servers will perform their own authorization. Duplicating that logic at the AS is premature before the resource server behaviour is settled.
- Authorization will move to a Policy Server later. The right moment to introduce AS-level enforcement is when the Policy Server defines the contract that the AS participates in.

---

## Decision

**Scope and audience enforcement are deferred. The AS issues tokens without binding them to a scope set or a specific FHIR server URL.**

- `aud` defaults to the KC client ID (standard Keycloak `client_credentials` behaviour). No per-FHIR-server audience scope is assigned.
- No scope set is configured per (caller, target FHIR server) pair. Scopes are not enforced by the AS.
- FHIR servers are responsible for their own access control until the Policy Server is in place.

---

## Consequences

- **Token replay risk.** A token is not bound to a specific FHIR server URL. Any FHIR server in the realm will accept it. This risk is accepted explicitly; FHIR servers mitigate it through their own authorization logic.
- **No AS-side scope audit trail.** There is no AS record of which scopes a hospital was provisioned for against a given FHIR server.
- Configuration is minimal: no `config/grants/` files, no per-server scope provisioning step.

---

## Revisit when

The Policy Server is introduced. At that point:

- `aud` enforcement should be reintroduced: tokens should be bound to a specific FHIR server URL and resource servers should validate it.
- Scope enforcement should be configured per (caller, target FHIR server) pair.

The per-server grants model implemented prior to this decision is preserved in a reference branch.
