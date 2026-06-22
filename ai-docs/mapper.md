---
recap: "FhirContextMapper — why it reads raw session notes instead of AuthorizationRequestContext, and the silent parse-error bug."
keywords: [FhirContextMapper.java, FhirContextMapper.java:98, authorization_details, client_request_param_authorization_details, AuthorizationRequestContext, client_credentials, fhirContext, session notes, WARN logging, parse errors, Keycloak 26.x, Apache-2.0, umzhconnect-sandbox]
---

# FhirContextMapper

Source: `keycloak/mapper/src/main/java/org/umzhconnect/keycloak/FhirContextMapper.java`  
Ported from `umzhconnect-sandbox` (Apache-2.0). Bundled into the image at build time via the multi-stage Dockerfile — no runtime volume mount needed.

## What it does

Maps RFC 9396 `authorization_details` of type `umzh-connect-context` into a `fhirContext` claim in the issued access token. The `identifier` field in the request becomes a `{ "reference": "<identifier>" }` entry in the JWT.

## Why it reads raw session notes

Keycloak 26.x does **not** populate `AuthorizationRequestContext` with custom `authorization_details` types for the `client_credentials` flow — only built-in SMART scope entries appear there. The mapper therefore reads the raw session notes directly:

- Key: `authorization_details`
- Fallback key: `client_request_param_authorization_details`

**Do not attempt to use the standard `AuthorizationRequestContext` API for this** — you will get empty results for every `client_credentials` token request.

## Silent parse-error bug (open gap)

`FhirContextMapper.java:98` swallows parse exceptions silently. A client sending malformed `authorization_details` gets a token with no `fhirContext` instead of any error. This should log at WARN level with the exception.
