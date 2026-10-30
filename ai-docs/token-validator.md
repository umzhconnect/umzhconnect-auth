---
recap: "Token validator mock resource server — env vars, endpoints, and the MAX_LIFETIME_SECONDS inconsistency to fix."
keywords: [ISSUER, JWKS_URI, EXPECTED_AUDIENCE, PORT, /validate, /fhir/Questionnaire, /fhir/Task, /fhir/:type/:id, MAX_LIFETIME_SECONDS, validator.ts:27, contextsOf, CONTEXT_TYPE, http://fhir.ch/ig/ch-umzh-connect/context, authorization_details, requireContext, WORKFLOW_ROOTS, TASKS, counter-party, context graph, context-gated, context gate, warn vs fail, per-check report, system/Patient.rs, system/Task.c]
---

# Token validator

Mock resource server at `token-validator/`. Dev/test only — not a production artifact.

## Configuration (environment variables)

| Variable | Required | Notes |
|----------|----------|-------|
| `ISSUER` | Yes | Expected `iss` value in tokens |
| `JWKS_URI` | Yes | Keycloak backchannel JWKS URL for signature verification |
| `PORT` | No | Default 8086 |
| `EXPECTED_AUDIENCE` | No | When set, enforces the IG audience restriction. `aud` is a constant identifying the umzh-connect ecosystem (the realm issuer URL), not a per-hospital FHIR URL — see [aud-design.md](aud-design.md) and [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md). Currently disabled (unset) in `docker-compose.yml` for the demo stack. |

## Endpoints

| Endpoint | Required scope | Notes |
|----------|---------------|-------|
| `POST /validate` | — | Body `{"token": "..."}` or `Authorization: Bearer`; returns per-check report |
| `GET /healthz` | — | Health check |
| `GET /fhir/Questionnaire/:id` | `system/Questionnaire.r…` | Not context-gated — scope only. The placer token lacks this scope → missing-scope negative test |
| `GET /fhir/Task/:id` | `system/Task.r…` | Not context-gated; caller's `organization_reference` must be `Task.requester` (mock `TASKS`) |
| `POST /fhir/Task` | `system/Task.c…` | `Task.requester` must be the caller, `Task.owner` the mock Fulfiller (hospital_b) |
| `GET /fhir/{type}/:id` | `system/{type}.r…` | Every other type is context-gated (`requireContext`) — see below |

There is no Organization route: cross-domain Organization data comes from the public registry, not from a hospital's FHIR server.

## Context gate (`requireContext`)

Implements the IG's checks for context-gated resources (security.md, "Counter-party entitlement is a Resource Server obligation"):

1. The token carries exactly one context: an `authorization_details` entry of type `http://fhir.ch/ig/ch-umzh-connect/context` (`contextsOf` in `validator.ts` ignores other types). Zero or more than one → 403.
2. `extensions.umzhconnect.organization_reference` is the counter-party the mock recorded for the root → otherwise 403.
3. The requested resource is in the root's context graph → otherwise 403.

The mock's records live in `WORKFLOW_ROOTS` (`index.ts`):
- `ServiceRequest/sr-123`: counter-party hospital_b, graph `ServiceRequest/sr-123`, `Patient/pat-1`, `Condition/cond-1`.
- `Task/task-456`: counter-party hospital_a, graph `DiagnosticReport/report-1`.

A real RS resolves the graph from its FHIR data.

`/validate` reports a `context` check: `skipped` without a context, `pass` with one, `fail` with more than one.

A `warn` result does not fail the request; only `fail` does. The `/validate` endpoint is the correctness oracle when developing clients or tweaking the Terraform config.

## Known inconsistency — MAX_LIFETIME_SECONDS

`validator.ts:27` sets `MAX_LIFETIME_SECONDS = 360` but the check message says "recommended <= 300s" and the realm is configured for 300 s. Fix the constant to `300` or update the message to match.
