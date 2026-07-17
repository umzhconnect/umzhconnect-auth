# 0004 — Reinstate L1 as an opt-in per-hospital debug client

**Status:** Accepted
**Date:** 2026-07-16
**Authors:** Trifork

---

## Context

L1 (`client_secret`) clients were removed entirely early in this repo's
history — see `ai-docs/open-gaps.md` ("Resolved: L1/L2/L3 direction: never
L1 in production") and the CLAUDE.md rule "Production is L2 only." The
reasoning stands for the general case: `client_secret` offers no
forward security and no non-repudiation for a healthcare data gateway
handling confidential data.

USZ and Balgrist have since asked for L1 support back, specifically for
**debugging** — `private_key_jwt` (L2) is harder to isolate through
firewalls, proxies, and JWKS-reachability issues than a plain
`client_secret` grant. They want to be able to confirm basic connectivity
and routing before (or instead of, initially) standing up the full L2 flow.

This is not a request to make L1 the default, or to weaken L2 as the
production baseline — it's a request for an explicit, opt-in fallback aimed
at the exact class of problem L2 makes hard to isolate.

---

## Decision

**Reinstate L1 as an explicit, per-hospital opt-in debug client. L2 remains
the default and the only client provisioned unless a hospital separately
opts into L1.**

- A new config directory, `keycloak/config/hospitals-l1/{org_id}.yaml`,
  independent of `keycloak/config/hospitals/{org_id}.yaml`. Presence of this
  file is the only gate — a hospital may have an L1 file, an L2 file, both,
  or neither. There is no requirement that the L2 file exist first: a
  hospital may start on L1 while debugging and move to L2 later, or run both
  side by side indefinitely.
- KC client ID `{org_id}--l1`, `client_authenticator_type = "client-secret"`,
  `service_accounts_enabled = true`. Same mapper set as
  the L2 client (`client-id-mapper`, `org-reference-mapper`,
  `fhir-context-mapper`, `ecosystem-audience-mapper`, `auth-level-mapper`),
  and the same default/optional scope assignment, so the debug client is
  otherwise a faithful stand-in for the real integration.
- **`auth_level` claim reinstated as a required claim on every M2M client,
  L1 and L2 alike** (`extensions.umzhconnect.auth_level`, `"L1"` or `"L2"`).
  This reactivates the claim deferred by [ADR 0001](0001-defer-auth-level-claim.md)
  — that deferral's premise ("only one level in use, so the claim carries no
  distinguishing information") no longer holds once L1 and L2 clients
  coexist. An earlier draft of this ADR stamped the claim only on the L1
  client, treating its absence as an implied `"L2"` — [PR review
  feedback](https://github.com/trifork/tch-umzh-connect-authentication-server/pull/13#discussion_r3596731042)
  pointed out that "implied by absence" is not intuitive and makes it easy
  to get a resource server's minimum-level check wrong (e.g. a bug that
  drops the claim mapper is indistinguishable from a legitimate L2 token).
  Every access token now carries an explicit `auth_level`, and any future L3
  client must stamp `"L3"` the same way — there's no level for which
  absence is a valid state. Resource servers can enforce a minimum level by
  checking the claim's value directly, with no absent-claim case to reason
  about.
- **Relaxed secret handling for L1 only.** The L1 client secret is
  Keycloak-generated (never hardcoded) and surfaced via a Terraform output,
  but — unlike a real production credential — it may be copied into a plain
  committed Secret manifest in `tch-umzh-connect-gitops` (the same pattern
  already used for `keycloak-admin-secret.yaml`, a dev-only plaintext
  secret) rather than routed through Vault/`ExternalSecret`. This is a
  deliberate, scoped exception because L1 is a debug-only path, not the
  production integration path — it is not a precedent for relaxing handling
  of the Keycloak admin password or any future real production secret.
- **Amends [ADR 0002](0002-one-client-per-hospital.md)**: "one client per
  hospital" is now "one *primary* (L2) client per hospital, plus an optional,
  explicitly tracked L1 debug client." The zero-implicit-access principle is
  preserved — a hospital gets an L1 client only via a deliberate, committed
  YAML file, exactly like the L2 path.
- **Supersedes** the "never L1 in production" resolution in
  `ai-docs/open-gaps.md` and the corresponding CLAUDE.md rule, both updated
  alongside this ADR.

---

## Consequences

- A hospital can have up to two KC clients: `{org_id}` (L2, default) and
  `{org_id}--l1` (L1, opt-in). Onboarding is unchanged for hospitals that
  don't request L1.
- Every access token now carries a required `auth_level` claim (`"L1"` or
  `"L2"`) distinguishing L1 from L2. Any resource server wanting to reject
  L1 tokens (e.g. treat L1 as debug-only and refuse it for real clinical
  data flows) can do so via this claim — enforcement is out of scope for
  this ADR and left to resource servers/a future Policy Server.
- This is a divergence from the sandbox realm, which has no `auth_level`
  claim on its (L2-only) tokens — acceptable because the claim's presence
  is additive and doesn't change how existing sandbox-compatible consumers
  parse the token.
- L1 client secrets get lighter-weight handling than other secrets in this
  project. This is an accepted, scoped risk tied to L1's debug-only purpose,
  not a general secret-hygiene downgrade.
- Revoking L1 access is symmetric with revoking a hospital entirely: delete
  `config/hospitals-l1/{org_id}.yaml` and `terraform apply`.

---

## Revisit when

- A resource server needs to actively enforce a minimum `auth_level` (rather
  than merely being able to read the claim) — likely coincides with Policy
  Server introduction (see ADR 0002's own "Revisit when").
- L1 usage patterns suggest it's becoming a de facto production path rather
  than a debug aid, at which point the relaxed secret handling should be
  reconsidered.
