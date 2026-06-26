# ADR 0005 — D2 named `aud:` scopes for audience binding

**Status:** Accepted — supersedes [ADR 0004](0004-rfc8707-resource-indicators.md) (RFC 8707 resource indicators)

---

## Context

ADR 0004 implemented audience binding via the `resource-indicators` KC experimental feature. The feature was labelled experimental in KC 26.6.1 and gated behind `--features=resource-indicators` at build time.

The feasibility analysis ([aud-d2-analysis.md](../../ai-docs/aud-d2-analysis.md)) documented D2 (named `aud:` scopes) as a fully implementable alternative using only standard KC scope and audience mapper machinery. The experimental feature risk is the primary motivation for switching.

---

## Decision

Replace `resource-indicators` with D2:

1. **One realm-level client scope `aud:{org_id}` per hospital** — created by Terraform in `clients.tf`. Each scope has `include_in_token_scope = false` (suppresses the scope name from the token's `scope` claim) and an audience mapper with `included_custom_audience = fhir_url`.

2. **Optional scope assignment from `allowed_targets`** — `scopes.tf` assigns `aud:{target}` as an optional scope on each M2M client for every entry in that hospital's `allowed_targets`. A hospital not listed cannot obtain a token scoped to that target.

3. **Token request uses `scope=`** — callers request `scope=aud:hospital-b` instead of `resource=<fhir_url>`. The `aud` value in the issued token is unchanged — still the FHIR URL.

What was removed:
- `--features=resource-indicators` from `Dockerfile` and `docker-compose.yml`
- `{org_id}-fhir-server` KC clients (RFC 8707 resource-server registrations)
- `keycloak_openid_audience_protocol_mapper.cross_hospital` resource
- `use_refresh_tokens_client_credentials = true` workaround (keycloak/keycloak#50251)

---

## Consequences

- No experimental KC feature dependency. Audience binding works on any KC 26.x version.
- Fewer KC objects. The `{org_id}-fhir-server` stub clients are gone; the `audience_pairs` cross-product local is gone.
- Callers must know the KC scope naming convention (`aud:hospital-b`) rather than using the FHIR URL directly. The error on an unauthorized target is `invalid_scope` rather than `invalid_target`.
- Token validators (`EXPECTED_AUDIENCE`) are unaffected — `aud` still carries the FHIR URL.
- Adding a new hospital: create `config/hospitals/{org_id}.yaml` with `fhir_url`, `jwks_url`, and `allowed_targets`, then `terraform apply`.

---

## Revisit when

- The Policy Server milestone is reached — layer per-(caller, target) scope grants on top of audience binding at that point.
- If the SMART on FHIR IG adopts the `resource` parameter as mandatory, reconsider RFC 8707 at that time.
