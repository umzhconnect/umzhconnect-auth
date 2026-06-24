---
recap: "Audience claim design — current state defers aud binding and scope enforcement to FHIR servers; D3 (RFC 8707) is the tracked future path."
keywords: [aud claim, audience, ADR 0002, ADR 0003, RFC 8707, resource parameter, keycloak/keycloak#47117, keycloak/keycloak#47118, D1-via-YAML, one client per hospital, scope enforcement, FHIR server, policy server, D3]
---

# Audience (`aud`) claim design

**Status:** Audience enforcement deferred — see ADR 0002 and ADR 0003.  
Full rationale: [`docs/adr/0002-one-client-per-hospital.md`](../docs/adr/0002-one-client-per-hospital.md) and [`docs/adr/0003-defer-scope-and-audience-enforcement.md`](../docs/adr/0003-defer-scope-and-audience-enforcement.md)

---

## Current implementation

One Keycloak client per hospital (org), identified by `{org_id}`. A hospital with no `config/hospitals/{org_id}.yaml` has no KC client and cannot obtain tokens.

`aud` in issued tokens defaults to the KC client ID (standard Keycloak `client_credentials` behaviour). No per-FHIR-server audience scope is configured. Scopes are not enforced at the AS level — FHIR servers handle their own authorization.

A token issued to `hospital-a` is not bound to a specific FHIR server URL; any FHIR server in the realm will accept it. This risk is accepted explicitly — FHIR servers mitigate it through their own access control. See ADR 0003.

---

## Why audience enforcement was deferred

USZ and Balgrist (UMZH) confirmed in the 2026-06-23 meeting that AS-level scope and audience enforcement is premature before FHIR server authorization behaviour is settled. Authorization will move to a Policy Server, and that is the right moment to introduce AS-level enforcement.

---

## Prior design (D1-via-YAML) — superseded

Before 2026-06-23, the design was one KC client per (org, app, target FHIR server) with per-server scope grants and `aud:<server_key>` default scopes. This was replaced by ADR 0002 when UMZH confirmed that this granularity is not needed at this stage. The per-server grants model is preserved in the git history on the pre-ADR-0002 commit.

---

## D3 migration path (RFC 8707 resource indicators)

When RFC 8707 support reaches preview in Keycloak (tracked as [keycloak/keycloak#47117](https://github.com/keycloak/keycloak/issues/47117) — milestoned for KC 26.8.0 as experimental):

| | Current (one client per hospital) | D3 (future) |
|---|---|---|
| KC clients | 1 per hospital | 1 per hospital (unchanged) |
| Token request | `client_id=hospital-a` | `client_id=hospital-a resource=https://fhir.hospital-b.example/fhir` |
| `aud` in token | KC client ID | FHIR server URL from `resource` param |
| Scope enforcement | None at AS | Per (caller, target) at AS |
| `config/hospitals/*.yaml` | unchanged | unchanged |
| Terraform change | — | Add per-client resource allow-list |

The YAML config stays the same. The main Terraform change is adding a resource allow-list per client; FHIR server URLs come from a new registry (equivalent of the old `fhir-servers.yaml`).
