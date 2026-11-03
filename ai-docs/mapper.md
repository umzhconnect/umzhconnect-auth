---
recap: "ContextExecutor + built-in session note mapper — how the RFC 9396 context is validated, stored and written into the token and token response."
keywords: [ContextExecutor.java, ContextExecutorFactory.java, umzh-context-executor, umzh-context client policy, umzh.context, user session note, oidc-usersessionmodel-note-mapper, authorization-details-mapper, jsonType.label JSON, access.tokenResponse.claim, authorization_details, http://fhir.ch/ig/ch-umzh-connect/context, invalid_authorization_details, RFC 9396, FAIL_ON_TRAILING_TOKENS, unknown fields, ServiceAccountTokenRequestContext, SERVICE_ACCOUNT_TOKEN_REQUEST, ClientPolicyException, AuthorizationDetailsProcessor, sanitizeBeforeSendingTokenResponse, client_credentials, Keycloak 26.x, umzh-context-mapper JAR, ADR 0005]
---

# Context executor and session note mapper

Source: `keycloak/mapper/src/main/java/org/umzhconnect/keycloak/`. The JAR is still called `umzh-context-mapper-*.jar` and is bundled into the image at build time by the multi-stage `keycloak/Dockerfile`. The context was originally handled by `FhirContextMapper`, ported from `umzhconnect-sandbox` (Apache-2.0). See [ADR 0005](../docs/adr/0005-context-authorization-details-claim.md) for the current design and why it diverges from the sandbox.

| Piece | Where | Role |
|-------|-------|------|
| `ContextExecutor` (+ `ContextExecutorFactory`) | this JAR, provider `umzh-context-executor` | Client-policy executor: validates `authorization_details` and stores the normalised context in the user session note `umzh.context` |
| `umzh-context` client profile + policy | `terraform/realm.tf` | Runs the executor for every client (`any-client`) |
| `authorization-details-mapper` | `terraform/clients.tf`, built-in `oidc-usersessionmodel-note-mapper` | Writes the note as the `authorization_details` claim and into the token response |

## Request rules (`ContextExecutor.identifier`)

- Parameter absent or blank → no context. This is valid: Task and Questionnaire need no context.
- Otherwise the parameter must be a JSON array holding exactly one object, with:
  - `type` equal to `http://fhir.ch/ig/ch-umzh-connect/context`;
  - a non-blank string `identifier`;
  - no other fields (RFC 9396 §5: unknown fields are refused, not dropped).
- Anything else is rejected with 400 `invalid_authorization_details`. That includes malformed JSON and trailing content after a valid array: the parser enables `FAIL_ON_TRAILING_TOKENS`, because Jackson's `readTree` otherwise ignores whatever follows the first value.
- The identifier's **content** is not checked; the Resource Server resolves it.

## Output

The executor stores the context as a JSON string in the user session note `umzh.context`. The built-in session note mapper (`jsonType.label = JSON`, `access.token.claim` and `access.tokenResponse.claim` both `true`) turns it into:

```json
"authorization_details": [
  { "type": "http://fhir.ch/ig/ch-umzh-connect/context", "identifier": "ServiceRequest/sr-123" }
]
```

This appears as a top-level access-token claim (RFC 9396 §9.1) and in the token response (RFC 9396 §7).

In the token response, the mapper puts the value in the generic claims. Keycloak's own `authorization_details` response field stays null, so two things follow:

- Keycloak's RAR sanitizing (`sanitizeBeforeSendingTokenResponse`) is skipped. Without a registered `AuthorizationDetailsProcessor` for the type, that step would return a 500.
- Keycloak serializes JSON without null fields, so the response carries a single `authorization_details` key.

## Why a client policy

A protocol mapper cannot fail a token request. Keycloak's RAR SPI (`AuthorizationDetailsProcessor`) is not invoked for `client_credentials`: in 26.7.2, `ClientCredentialsGrantType` only stores the raw parameter as a session note.

The grant does fire the client-policy event `SERVICE_ACCOUNT_TOKEN_REQUEST`, and it fires it before building the token. The event's `ServiceAccountTokenRequestContext` carries the form parameters and the client session, and through the client session the user session. A `ClientPolicyException` thrown there becomes an HTTP 400 carrying the exception's error code.

**The policy is required for every context.** If the `umzh-context` profile or policy is missing, tokens carry no context at all and nothing is logged; context-gated reads then fail with 403. This fails closed, and Bruno `auth/05` and `auth/08` catch it.

**The design depends on event order:** the event must fire before the token is built. This holds on Keycloak 26.7.2 and 26.8.1. Re-run Bruno on every Keycloak upgrade.
