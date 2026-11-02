# ADR 0005 — Carry the context as an RFC 9396 `authorization_details` claim

**Status:** Accepted
**Date:** 2026-10-30 (revised 2026-11-02 after the review of umzhconnect-auth#5)

## Context

UMZH Connect binds a token to one workflow root (a `ServiceRequest` on the Placer, a `Task` on the Fulfiller). The client names that root in the RFC 9396 `authorization_details` token request parameter.

Until now the realm mirrored `umzhconnect-sandbox`: the request type was `umzh-connect-context`, and `FhirContextMapper` turned it into a SMART-style `fhirContext: [{reference}]` claim. It never rejected a request. Unknown types and malformed JSON were silently dropped, and several contexts produced several `fhirContext` entries.

The IG changed this in umzhconnect-ig#135 (issues #124, #125). An open IG PR renames the type URI and the mapper, and this repo follows that PR:

- Type: `http://fhir.ch/ig/ch-umzh-connect/context`. The published IG still says `.../workflow-context`, but the open PR changes it to this value. Fields are `type` 1..1 and `identifier` 1..1.
- "A token request carries at most one workflow context; otherwise the AS MUST reject it with `invalid_authorization_details`."
- "The Authorization Server returns the granted `authorization_details` in the token response (RFC 9396 §7) and carries them as a top-level `authorization_details` claim in the issued JWT access token (RFC 9396 §9.1)."
- `fhirContext` is no longer mentioned anywhere in the IG.

RFC 9396 §5 also requires the AS to refuse unknown authorization details types and "an object of known type but containing unknown fields".

Keycloak 26.7.2 constraints, checked against the server JARs:

- A protocol mapper cannot fail a token request.
- Keycloak's own RAR SPI (`AuthorizationDetailsProcessor`) is not invoked for the `client_credentials` grant. `ClientCredentialsGrantType` only copies the raw parameter into a session note.
- `ClientCredentialsGrantType` does fire the client-policy event `SERVICE_ACCOUNT_TOKEN_REQUEST` with the form parameters. It turns a `ClientPolicyException` into an HTTP 400 carrying the exception's error code.
- That event fires before Keycloak builds the token, and its context exposes the client session, and through it the user session.
- Keycloak's built-in user session note mapper (`oidc-usersessionmodel-note-mapper`) can write a JSON note as a claim in the access token and, with `access.tokenResponse.claim = true`, in the token response. It puts the value in the response's generic claims. Keycloak's own `authorization_details` response field stays null, so Keycloak's RAR sanitizing (which needs a registered processor per type) is skipped.

## Decision

1. **Switch fully, now.** There is no transition period: no `fhirContext` claim and no acceptance of `umzh-connect-context`. This intentionally diverges from today's `umzhconnect-sandbox`; see [realm-contract.md](../../ai-docs/realm-contract.md).
2. **The AS rejects with 400 `invalid_authorization_details`** when the parameter has:
   - malformed JSON, including trailing content after a valid value;
   - a value that is not a non-empty JSON array, or an entry that is not an object;
   - an unknown or missing `type`;
   - a field other than `type` and `identifier` (RFC 9396 §5: unknown fields are refused, not dropped);
   - a missing, blank or non-string `identifier`;
   - more than one context.
3. **One custom provider.** A client-policy executor, `umzh-context-executor` (`ContextExecutor`), both validates the request and stores the granted context in the user session note `umzh.context`. It runs in a realm client profile and policy named `umzh-context` that applies to `any-client`. Terraform manages both in `terraform/realm.tf`.
4. **Built-in mapper for the output.** Keycloak's `oidc-usersessionmodel-note-mapper` (`authorization-details-mapper` in `terraform/clients.tf`) writes the note, exactly `[{"type": "<URI>", "identifier": "<id>"}]`, as the top-level `authorization_details` access-token claim and into the token response. There is no custom protocol mapper and no RAR processor.
5. **The identifier's content is not checked**, for example whether it is a `ServiceRequest/{id}` or `Task/{id}` reference. The AS also does not cross-check the identifier against the requested scopes. The Resource Server resolves the identifier against its own workflow data and remains the sole judge of counter-party entitlement.

## Consequences

- Tokens and token responses match the IG. Clients that still send `umzh-connect-context` now receive a 400 instead of a context-free token, so the failure is visible at the token endpoint and not later as a 403 at the Resource Server.
- **Sandbox parity is broken until the sandbox follows the IG.** The sandbox's Hurl suites `05-cross-party-context.hurl` and `08-context-enforcement.hurl`, and its OPA policies, still send `umzh-connect-context` and read `fhirContext`, so they fail against this realm.
- **The client policy is required for every context, not only for rejection.** If the `umzh-context` profile or policy is missing (for example in a realm not provisioned by Terraform), tokens carry no context at all and Keycloak logs nothing about it; context-gated reads then fail with 403. This fails closed and is caught by Bruno `auth/05` and `auth/08`.
- **The design relies on the client-policy event firing before the token is built.** That holds on Keycloak 26.7.2 and 26.8.1. If the order changes, contexts disappear and Bruno `auth/05` and `auth/08` fail.
- The Terraform mapper resources are renamed (`fhir_context` → `context`, `fhir_context_l1` → `context_l1`), with `moved` blocks. The mapper type changes from a custom to the built-in session note mapper, so Terraform replaces the mappers on the next apply.
- **Old mapper rows stay behind, invisible.** Keycloak hides a protocol mapper whose provider is no longer in the image: the admin API neither lists nor returns it. Terraform therefore treats the old `fhir-context-mapper` as already gone and never deletes it. The database row remains, is ignored at token issuance, and still reserves its name. That is why the new mapper has its own name (`authorization-details-mapper`, not `fhir-context-mapper` or the `context-mapper` of this PR's first revision).
- Open gap #2 (silent parse errors in the mapper) is resolved: invalid requests now fail at the token endpoint.
- One provider depends on an internal Keycloak SPI (`client-policy-executor`); Keycloak logs KC-SERVICES0047 for it at startup. Re-test on every Keycloak upgrade (Bruno `auth/05`, `auth/08`, `negative/08`, `11`–`13`, `18`, `19`).
- The image is still custom (the executor JAR, `umzh-context-mapper-*.jar`); this was already the case with the old mapper.

## Revisit when

- Keycloak runs RAR `AuthorizationDetailsProcessor`s for `client_credentials`. Our type would then be refused as unsupported unless a processor is registered for it; such a processor could also replace the client policy.
- The IG's open PR merges with a different type URI or field set.
