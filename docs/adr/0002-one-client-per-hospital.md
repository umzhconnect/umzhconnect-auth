# 0002 — One Keycloak client per hospital

**Status:** Accepted  
**Date:** 2026-06-23  
**Authors:** Trifork

---

## Context

The UMZH Connect ecosystem connects hospitals acting as both referral sources (placers) and referral targets (fulfillers). Each hospital may operate several applications (LIS, portal, etc.), each of which needs M2M access to FHIR servers operated by other hospitals.

An earlier design modelled this as one KC client per (org, app, target FHIR server) — a fan-out that produces O(N × M × N) clients at N hospitals, M apps per hospital, N target FHIR servers. The driver for that granularity was AS-level scope and audience enforcement: each client was scoped to a specific FHIR server with a specific scope set.

USZ and Balgrist (UMZH) confirmed in the 2026-06-23 meeting that this granularity is not needed at this stage. Authorization will be handled by the FHIR servers themselves for now, and later by a Policy Server. The AS's role is authentication and identity — not authorization.

---

## Decision

**One Keycloak client per hospital (org), provisioned explicitly at onboarding.**

- KC client ID: `{org_id}`.
- All production clients authenticate with `private_key_jwt` (L2). `client_secret` is banned from production.
- A hospital gets a KC client only when deliberately onboarded. Zero-implicit-access: a hospital with no KC client cannot obtain tokens.
- Per-app identity within a hospital is not modelled at this time. All applications operated by a hospital share one KC client identity.
- All KC clients remain Terraform-managed. No manual KC admin console changes.

---

## Consequences

- KC client count is O(N) — one per hospital, regardless of how many apps or FHIR servers are in the network.
- Onboarding a new hospital requires provisioning one KC client. No per-server or per-app configuration is needed.
- Per-app distinguishability within a hospital is not available at the AS level. If this becomes necessary (e.g. for audit or per-app revocation), the model must be extended to one client per (hospital, app).

---

## Revisit when

The Policy Server is introduced. At that point, per-app identity may be required depending on how the Policy Server models access subjects.
