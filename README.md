# UMZH Connect — Authentication Server

Keycloak-based OAuth 2.0 Authorization Server for the
[UMZH Connect](https://github.com/umzhconnect/umzhconnect-ig) ecosystem,
implementing the IG's machine-to-machine security model:

- `client_credentials` grant with SMART on FHIR **system scopes**
  (`system/<Resource>.<perms>`)
- staged client authentication: **Level 1** (`client_secret`, sandbox/PoC) and
  **Level 2** (`private_key_jwt` per SMART Backend Services, production
  baseline) — Level 3 (mTLS/DPoP) is out of scope
- **RFC 9396** `authorization_details` (type `umzh-connect-context`) mapped to
  a SMART v2 `fhirContext` claim by a custom Keycloak protocol mapper
- `extensions.umzhconnect.organization_reference` claim set by the AS from the
  client's onboarding record

The realm contract is kept identical to the
[umzhconnect-sandbox](https://github.com/umzhconnect/umzhconnect-sandbox), so
this Keycloak is a **drop-in replacement** for the sandbox's `keycloak`
service.

## Layout

| Path | Contents | Production artifact? |
|------|----------|----------------------|
| `keycloak/` | Custom Keycloak image (Dockerfile + `FhirContextMapper` provider) and the Terraform realm configuration | **Yes** (image + config) |
| `token-validator/` | Mock resource server that validates tokens per the IG and exposes sample protected endpoints | No — dev/test aid only |
| `bruno/` | Bruno collection: token acquisition (L1/L2/context), validation calls, negative cases | No |
| `keys/` | Committed **demo** Level 2 client keys (sandbox parity) | No |

The `FhirContextMapper` source and the demo keys are ported from
`umzhconnect-sandbox` (Apache-2.0).

## Quick start

```sh
docker compose up -d --build
```

This starts:

| Service | URL | Notes |
|---------|-----|-------|
| Keycloak | http://localhost:8180 | admin / admin; issuer `http://localhost:8180/realms/umzh-connect` |
| keycloak-config | — | one-shot Terraform apply configuring the realm; state lands in `keycloak/terraform/` (gitignored) |
| jwks-server | http://localhost:8085 | serves the L2 demo client JWKS |
| token-validator | http://localhost:8086 | `POST /validate`, `GET /healthz`, mock FHIR endpoints |

After a Terraform config change, re-apply with:

```sh
docker compose up keycloak-config
```

(or run `terraform apply` directly in `keycloak/terraform/` with
`TF_VAR_keycloak_url=http://localhost:8180`).

### Smoke test

```sh
# Discovery (no auth required)
curl -s http://localhost:8180/realms/umzh-connect/.well-known/openid-configuration | jq .issuer

# Token validator health
curl -s http://localhost:8086/healthz
```

All production clients authenticate with `private_key_jwt` (L2). Use the Bruno collection for full token acquisition and validation flows — see [Bruno collection](#bruno-collection) below.

## Bruno collection

Open `bruno/` in [Bruno](https://www.usebruno.com/) and select the `local`
environment. Suggested order: `auth/` (discovery, L1/L2/context tokens) →
`validation/` → `negative/`.

### Sandbox mode (required for L2 requests)

The Level 2 pre-request scripts use Node.js built-ins (`crypto`, `fs`, `path`)
to sign the RFC 7523 client assertion locally. Bruno's **default sandbox is
QuickJS**, which does not expose these modules, so L2 requests will fail with
`Cannot find module crypto` unless you switch to the Node.js sandbox:

- **CLI:** always pass `--sandbox unsafe`
  ```sh
  bru run --env local --sandbox unsafe
  ```
- **Desktop app:** click the **green shield icon** in the top-right of the
  collection window and switch to *"Developer mode"*.

The `unsafe` label is Bruno's terminology; it simply means *"run scripts in
Node.js instead of QuickJS"*. The L1, validation, and negative requests do not
use `require()` and work in either sandbox.

If Bruno cannot resolve the demo key path, set the `l2KeysDir` environment
variable in `bruno/environments/local.bru` to the absolute path of `keys/`.

## Token validator (mock resource server)

Configuration (env): `ISSUER` (expected `iss`), `JWKS_URI` (signature keys,
backchannel), `EXPECTED_AUDIENCE` (optional — enforces the IG's
audience-restriction when set), `PORT`.

Endpoints:

- `POST /validate` — body `{"token": "..."}` or `Authorization: Bearer`;
  returns a per-check report (signature, issuer, expiry, audience, algorithm,
  lifetime, scopes, `organization_reference`, `fhirContext`, `realm_roles`)
- `GET /fhir/Patient/:id` — requires `system/Patient.r`
- `GET /fhir/Organization/:id` — requires `system/Organization.r` (the placer
  client lacks it → negative test)
- `GET /fhir/ServiceRequest/:id` — requires scope **and** a `fhirContext`
  covering the resource (context gate)
- `POST /fhir/Task` — requires `system/Task.c…`

## Drop-in replacement for the sandbox

To swap this Keycloak into `umzhconnect-sandbox`:

1. In the sandbox `docker-compose.yml`, replace the `keycloak` service image
   with this repo's `keycloak/` build (it already contains the mapper — the
   sandbox's `keycloak-mapper-build` service and the `--import-realm` flag and
   realm/provider volume mounts become unnecessary).
2. Update `keycloak/config/hospitals/*.yaml` with the sandbox JWKS endpoint
   URLs (e.g. `jwks_url: "http://apisix-placer-external:9080/jwks.json"`),
   then apply:
   ```sh
   TF_VAR_keycloak_url=http://localhost:8180 \
     terraform -chdir=keycloak/terraform apply -auto-approve
   ```
3. The realm name, issuer URL (`http://localhost:8180/realms/umzh-connect`),
   SMART scope vocabulary, and custom claims match the sandbox realm export.
   Acceptance test: run the sandbox's Hurl suites (`tests/`).


## Architecture decisions

Significant design choices and conscious non-decisions are recorded as ADRs in
[`docs/adr/`](docs/adr/README.md).

## Use cases / operator runbook

How to process operational requests (onboarding, key rotation, offboarding,
incidents) and the reference token-flow behaviors are documented in
[`docs/use-cases/operational.md`](docs/use-cases/operational.md) and
[`docs/use-cases/technical.md`](docs/use-cases/technical.md).

## Production notes

Only the Keycloak image + realm configuration are production-bound. The
deployment flow (snapshot/export of the applied realm, real secrets, TLS,
`start --optimized`) is intentionally not part of this scaffolding yet. All
credentials in this repo are demo values.
