---
recap: "RFC standards analysis for the aud claim — RFC 7519 (optional), RFC 9068 (required, scope inference permitted), RFC 6749 (scopes application-defined, SHOULD appear in token), RFC 8707 (target standard, KC experimental)."
keywords: [aud claim, audience, RFC 7519, RFC 9068, RFC 8707, RFC 6749, resource indicators, scope inference, aud:scope, constant aud, JWT profile, OAuth 2.0, client credentials, scope claim, include_in_token_scope]
---

# Audience (`aud`) Claim — Standards Analysis

## RFC 7519 — JSON Web Token (JWT)

https://www.rfc-editor.org/rfc/rfc7519

RFC 7519 is the base JWT specification. It defines the `aud` claim as **optional**. However, if the claim is present, it imposes a strict validation obligation on every recipient:

> "If the principal processing the claim does not identify itself with a value in the `aud` claim when this claim is present, then the JWT MUST be rejected." (RFC 7519 §4.1.3)

This means a constant domain-wide audience value (e.g. `https://umzh-connect.example`) is technically valid under RFC 7519 — every hospital in the ecosystem can identify itself with that value and no rejection is triggered. The trade-off is that the isolation mechanism the claim is designed to enforce is rendered inert: a token issued to hospital-a can be presented to hospital-b without any audience-level rejection. Whether that is acceptable depends on the threat model and what compensating controls exist at other layers (mTLS, network segmentation, application-level checks).

---

## RFC 9068 — JWT Profile for OAuth 2.0 Access Tokens

https://www.rfc-editor.org/rfc/rfc9068

RFC 9068 is a narrowing profile on top of RFC 7519 specifically for OAuth 2.0 access tokens. It makes `aud` **required** and tightens its semantics:

> "`aud` — REQUIRED. … Authorization servers SHOULD use the `resource` parameter to determine the value of this claim." (RFC 9068 §2.2)

The `aud` value must identify the **resource server(s)** the token is intended for, not just any arbitrary recipient. Conformance to RFC 9068 therefore rules out omitting `aud` entirely, and a constant value representing the whole solution domain conflicts with the intent of the claim even if it is not a literal syntax violation.

---

## RFC 6749 §3.3 — Scopes are application-defined

https://www.rfc-editor.org/rfc/rfc6749#section-3.3

RFC 6749 is the base OAuth 2.0 specification. It defines the scope parameter format but deliberately leaves the meaning of individual scope values to the authorization server:

> "The value of the scope parameter is expressed as a list of space-delimited, case-sensitive strings. **The strings are defined by the authorization server.**" (RFC 6749 §3.3)

This is the direct basis for using `aud:hospital-b` as a scope name. There is no globally standardised scope namespace — each AS defines its own. A scope named `aud:hospital-b` is therefore fully within the specification; the AS assigns its meaning and determines what it triggers internally.

RFC 6749 §3.3 further specifies how granted scopes relate to the issued token:

> "If the client omits the scope parameter when requesting authorization, the authorization server MUST either process the request using a pre-defined default value or fail the request indicating an invalid scope."

And on scope representation in the token, RFC 9068 §2.2.3 adds two statements:

> "If an authorization request includes a scope parameter, the corresponding issued JWT access token SHOULD include a `scope` claim." (RFC 9068 §2.2.3)

> "All the individual scope strings in the `scope` claim MUST have meaning for the resources indicated in the `aud` claim." (RFC 9068 §2.2.3)

Both statements support suppressing `aud:hospital-b` from the token's `scope` claim. The first uses SHOULD (not MUST), so inclusion is a recommendation rather than a hard requirement. The second adds a positive constraint: any scope string that does appear in the `scope` claim must be meaningful to the resource server identified in `aud`. Since `aud:hospital-b` is an AS-internal routing token with no defined meaning at the FHIR resource server, including it would conflict with this MUST. Suppressing it is therefore not only permitted but the more correct behaviour.

---

## RFC 9068 §3 — Inferring `aud` from the scope parameter

RFC 9068 explicitly addresses the case where no `resource` parameter (RFC 8707) is present in the token request:

> "The authorization server MUST use a default resource indicator in the `aud` claim. The authorization server MAY use the `scope` parameter to infer the resource indicator." (RFC 9068 §3)

Using a dedicated scope (e.g. `scope=aud:hospital-b`) to drive the `aud` claim — the D2 design formerly implemented in this repo, since removed per [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md) — is a pattern the RFC explicitly anticipates and permits. The mechanism was Keycloak-specific in its plumbing, but the approach has normative grounding in RFC 9068 §3.

---

## RFC 8707 — Resource Indicators for OAuth 2.0

https://www.rfc-editor.org/rfc/rfc8707

RFC 8707 is the dedicated standard for a caller to explicitly request a specific audience at token-request time. It introduces a `resource` parameter in the token request whose value is the URI of the intended resource server:

```
POST /token
  grant_type=client_credentials
  resource=https://fhir.hospital-b.example/fhir
```

The authorization server binds `aud` directly to that URI. This is the most explicit and standards-aligned approach: the request mechanism, the audience binding, and the resulting token claim all have direct RFC backing with no inference required.

RFC 8707 is the target standard this implementation should migrate to. However, Keycloak's support for resource indicators is currently gated behind an experimental feature flag (`--features=resource-indicators`), which carries production risk. Per [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md), the current interim is a constant ecosystem-wide `aud` rather than the scope-based inference approach described above — see that ADR for why the per-target mechanism was removed rather than kept as a fallback.

---

## Summary

| Aspect | RFC 7519 | RFC 6749 | RFC 9068 | RFC 8707 |
|--------|----------|----------|----------|----------|
| `aud` required? | No — optional | Not addressed | Yes — required | N/A (request-side) |
| Semantics | Recipients the JWT is intended for | N/A | The resource server(s) the access token targets | Resource server URI requested by the caller |
| Constant domain-wide value | Technically valid; security boundary is lost | N/A | Conflicts with intent | N/A |
| Scope values defined by | N/A | Authorization server (§3.3) | N/A | N/A |
| Requested scopes in token | N/A | Not specified | SHOULD appear in `scope` claim (§2.2) | N/A |
| Inferring `aud` from scope | Not addressed | N/A | Explicitly permitted (§3) | N/A — URI stated directly |
| Keycloak support | — | — | Token content handled natively | Experimental feature flag only |
