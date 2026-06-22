---
recap: "Token validator mock resource server — env vars, endpoints, and the MAX_LIFETIME_SECONDS inconsistency to fix."
keywords: [ISSUER, JWKS_URI, EXPECTED_AUDIENCE, PORT, /validate, /fhir/Patient, /fhir/Organization, /fhir/ServiceRequest, /fhir/Task, MAX_LIFETIME_SECONDS, validator.ts:27, fhirContext gate, context gate, warn vs fail, per-check report, system/Patient.r, system/Task.c]
---

# Token validator

Mock resource server at `token-validator/`. Dev/test only — not a production artifact.

## Configuration (environment variables)

| Variable | Required | Notes |
|----------|----------|-------|
| `ISSUER` | Yes | Expected `iss` value in tokens |
| `JWKS_URI` | Yes | Keycloak backchannel JWKS URL for signature verification |
| `PORT` | No | Default 8086 |
| `EXPECTED_AUDIENCE` | No | When set, enforces the IG audience restriction. Currently disabled in `docker-compose.yml` because the realm does not yet set a correct `aud` (see [aud-design.md](aud-design.md)). |

## Endpoints

| Endpoint | Required scope | Notes |
|----------|---------------|-------|
| `POST /validate` | — | Body `{"token": "..."}` or `Authorization: Bearer`; returns per-check report |
| `GET /healthz` | — | Health check |
| `GET /fhir/Patient/:id` | `system/Patient.r` | — |
| `GET /fhir/Organization/:id` | `system/Organization.r` | Placer client lacks this → good negative test |
| `GET /fhir/ServiceRequest/:id` | `system/ServiceRequest.rs` + `fhirContext` covering the resource | Context gate test |
| `POST /fhir/Task` | `system/Task.c…` | — |

A `warn` result does not fail the request; only `fail` does. The `/validate` endpoint is the correctness oracle when developing clients or tweaking the Terraform config.

## Known inconsistency — MAX_LIFETIME_SECONDS

`validator.ts:27` sets `MAX_LIFETIME_SECONDS = 360` but the check message says "recommended <= 300s" and the realm is configured for 300 s. Fix the constant to `300` or update the message to match.
