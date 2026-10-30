---
recap: "ContextMapper, ContextExecutor, ContextProcessor — how the RFC 9396 context reaches the token and token response, why the mapper reads raw session notes, and why rejection is a client policy."
keywords: [ContextMapper.java, ContextExecutor.java, ContextExecutorFactory.java, ContextProcessor.java, ContextProcessorFactory.java, ContextAuthorizationDetails.java, AuthorizationDetailsParser.registerParser, sanitizeBeforeSendingTokenResponse, umzh-context-mapper, umzh-context-executor, umzh-context client policy, authorization_details, http://fhir.ch/ig/ch-umzh-connect/context, invalid_authorization_details, RFC 9396, OIDCAccessTokenResponseMapper, access.tokenResponse.claim, ServiceAccountTokenRequestContext, SERVICE_ACCOUNT_TOKEN_REQUEST, ClientPolicyException, client_request_param_authorization_details, AuthorizationRequestContext, AuthorizationDetailsProcessor, client_credentials, session notes, WARN logging, Keycloak 26.x, ADR 0005]
---

# Context mapper, executor and processor

Source: `keycloak/mapper/src/main/java/org/umzhconnect/keycloak/`. The JAR is `umzh-context-mapper-*.jar`. It is bundled into the image at build time by the multi-stage `keycloak/Dockerfile`, with no runtime volume mount. It was originally ported from `umzhconnect-sandbox` (Apache-2.0) as `FhirContextMapper`. See [ADR 0005](../docs/adr/0005-context-authorization-details-claim.md) for why it now diverges from the sandbox.

| Class | Provider ID | Role |
|-------|-------------|------|
| `ContextAuthorizationDetails` | — | Shared parser and rules for the context type `http://fhir.ch/ig/ch-umzh-connect/context` |
| `ContextExecutor` (+ `ContextExecutorFactory`) | `umzh-context-executor` | Client-policy executor that rejects invalid token requests with 400 `invalid_authorization_details` |
| `ContextMapper` | `umzh-context-mapper` | Protocol mapper that writes the context into the access token and the token response |
| `ContextProcessor` (+ `ContextProcessorFactory`) | `http://fhir.ch/ig/ch-umzh-connect/context` | RAR `AuthorizationDetailsProcessor` that lets the context pass Keycloak's token-response sanitizing |

## Request rules (`ContextAuthorizationDetails.parse`)

- Parameter absent or blank → no context. This is valid: Task and Questionnaire need no context.
- Otherwise the parameter must be a non-empty JSON array of objects. Every entry must have `type` equal to the UMZH context URI and a non-blank string `identifier`. At most one entry is allowed.
- Anything else is rejected (RFC 9396 §5): malformed JSON, an unknown type, a missing identifier, or two or more contexts.
- The identifier's **content** is not checked; the Resource Server resolves it.

## Output

Both the access token (top-level claim, RFC 9396 §9.1) and the token response (RFC 9396 §7) carry exactly:

```json
"authorization_details": [
  { "type": "http://fhir.ch/ig/ch-umzh-connect/context", "identifier": "ServiceRequest/sr-123" }
]
```

Extra request fields are dropped. The token response part works only when the mapper config sets `access.tokenResponse.claim = "true"`, which `terraform/clients.tf` does. `AbstractOIDCProtocolMapper` skips `setClaim(AccessTokenResponse, …)` otherwise.

## Why a RAR processor is needed for the token response

Before sending a token response, `OAuth2GrantTypeBase.createTokenResponse` passes every `authorization_details` entry through `AuthorizationDetailsProcessorManager.sanitizeBeforeSendingTokenResponse`. That method:

- looks up a processor **by factory ID**, not by `getSupportedType()`. `ContextProcessorFactory`'s ID must therefore be the type URI itself;
- converts the entry with `asSubtype()`. That needs a parser registered for the type through `AuthorizationDetailsParser.registerParser`, which `ContextProcessorFactory.init` does as a pass-through.

Without either, a valid context request fails with HTTP 500 (`Unsupported type ...` or `Unsupported to parse response of type ...`). Keycloak never calls the processor's `process()` for `client_credentials`, so request validation stays in `ContextExecutor`.

## Why rejection is a client policy

A protocol mapper cannot fail a token request. Keycloak's RAR SPI (`AuthorizationDetailsProcessor`) is not invoked for `client_credentials`: in 26.7.2, `ClientCredentialsGrantType` only stores the raw parameter as a session note.

The grant does fire the client-policy event `SERVICE_ACCOUNT_TOKEN_REQUEST`. That event carries the form parameters through `ServiceAccountTokenRequestContext`, and the grant turns a `ClientPolicyException` into an HTTP 400 with the exception's error code. `terraform/realm.tf` registers the executor in the `umzh-context` client profile and policy, which apply to `any-client`.

If that policy is missing (for example in a realm not provisioned by Terraform), invalid requests are no longer rejected. The mapper still emits no context for them and logs a WARN naming the client.

## Why the mapper reads raw session notes

Keycloak 26.x does **not** populate `AuthorizationRequestContext` with custom `authorization_details` types for the `client_credentials` flow; only built-in SMART scope entries appear there. The mapper therefore reads the raw session notes directly:

- Key: `authorization_details`
- Fallback key: `client_request_param_authorization_details`

**Do not use the standard `AuthorizationRequestContext` API for this.** It returns empty results for every `client_credentials` token request.
