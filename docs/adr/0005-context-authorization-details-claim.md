# ADR 0005 — Carry the context as an RFC 9396 `authorization_details` claim

**Status:** Accepted
**Date:** 2026-10-30

## Context

UMZH Connect binds a token to one workflow root (a `ServiceRequest` on the Placer, a `Task` on the Fulfiller). The client names that root in the RFC 9396 `authorization_details` token request parameter.

Until now the realm mirrored `umzhconnect-sandbox`: the request type was `umzh-connect-context`, and `FhirContextMapper` turned it into a SMART-style `fhirContext: [{reference}]` claim. It never rejected a request. Unknown types and malformed JSON were silently dropped, and several contexts produced several `fhirContext` entries.

The IG changed this in umzhconnect-ig#135 (issues #124, #125). An open IG PR renames the type URI and the mapper, and this repo follows that PR:

- Type: `http://fhir.ch/ig/ch-umzh-connect/context`. The published IG still says `.../workflow-context`, but the open PR changes it to this value. Fields are `type` 1..1 and `identifier` 1..1.
- "A token request carries at most one workflow context; otherwise the AS MUST reject it with `invalid_authorization_details`."
- "The Authorization Server returns the granted `authorization_details` in the token response (RFC 9396 §7) and carries them as a top-level `authorization_details` claim in the issued JWT access token (RFC 9396 §9.1)."
- `fhirContext` is no longer mentioned anywhere in the IG.

RFC 9396 §5 also requires the AS to refuse unknown authorization details types.

Keycloak 26.7.2 constraints, checked against the server JARs:

- A protocol mapper cannot fail a token request.
- Keycloak's own RAR SPI (`AuthorizationDetailsProcessor`) is not invoked for the `client_credentials` grant. `ClientCredentialsGrantType` only copies the raw parameter into a session note.
- `ClientCredentialsGrantType` does fire the client-policy event `SERVICE_ACCOUNT_TOKEN_REQUEST` with the form parameters. It turns a `ClientPolicyException` into an HTTP 400 carrying the exception's error code.
- `AbstractOIDCProtocolMapper` can modify the token response (`OIDCAccessTokenResponseMapper`) when the mapper config sets `access.tokenResponse.claim = true`.

## Decision

1. **Switch fully, now.** There is no transition period: no `fhirContext` claim and no acceptance of `umzh-connect-context`. This intentionally diverges from today's `umzhconnect-sandbox`; see [realm-contract.md](../../ai-docs/realm-contract.md).
2. **The AS rejects with 400 `invalid_authorization_details`** when the parameter has:
   - malformed JSON;
   - a value that is not a non-empty JSON array, or an entry that is not an object;
   - an unknown or missing `type`;
   - a missing or blank `identifier`;
   - more than one context.

   The rejection is done by a client-policy executor, `umzh-context-executor` (`ContextExecutor`), in a realm client profile and policy named `umzh-context` that applies to `any-client`. Terraform manages both in `terraform/realm.tf`.
3. **The identifier's content is not checked**, for example whether it is a `ServiceRequest/{id}` or `Task/{id}` reference. The AS also does not cross-check the identifier against the requested scopes. The Resource Server resolves the identifier against its own workflow data and remains the sole judge of counter-party entitlement.
4. **Normalised output.** `ContextMapper` (provider ID `umzh-context-mapper`, the name used in the open IG PR; previously `umzh-fhir-context-mapper`) writes exactly `[{"type": "<URI>", "identifier": "<id>"}]`, both as the top-level `authorization_details` access-token claim and in the token response. Extra request fields are dropped.
5. **A RAR processor for the type** (`ContextProcessor`, whose factory ID is the type URI) and a pass-through `AuthorizationDetailsParser` are registered. They exist only because Keycloak sanitizes every token-response `authorization_details` entry through the processor for its type, and returns a 500 for a type that has none. They do not validate `client_credentials` requests.
6. **No silent loss.** If the client policy is missing, the mapper still refuses to emit an invalid context, and it logs a WARN instead of failing silently.

## Consequences

- Tokens and token responses match the IG. Clients that still send `umzh-connect-context` now receive a 400 instead of a context-free token, so the failure is visible at the token endpoint and not later as a 403 at the Resource Server.
- **Sandbox parity is broken until the sandbox follows the IG.** The sandbox's Hurl suites `05-cross-party-context.hurl` and `08-context-enforcement.hurl`, and its OPA policies, still send `umzh-connect-context` and read `fhirContext`, so they fail against this realm.
- The realm now depends on a client policy. A realm that is not provisioned by Terraform must create the `umzh-context` profile and policy itself, or invalid requests fall back to the mapper's WARN-and-drop behaviour.
- The Terraform mapper resources are renamed (`fhir_context` → `context`, `fhir_context_l1` → `context_l1`), with `moved` blocks. The provider ID changes, so Terraform replaces the mappers on the next apply.
- Open gap #2 (silent parse errors in the mapper) is resolved.
- Three providers depend on internal Keycloak SPIs (`protocol-mapper`, `client-policy-executor`, `authorization-details-processor`); Keycloak logs KC-SERVICES0047 for each at startup. Re-test on every Keycloak upgrade (Bruno `auth/05`, `auth/08`, `negative/08`, `11`–`13`).

## Revisit when

- Keycloak runs RAR `AuthorizationDetailsProcessor`s for `client_credentials`. A processor for the context type could then replace the client policy.
- The IG's open PR merges with a different type URI or field set.
