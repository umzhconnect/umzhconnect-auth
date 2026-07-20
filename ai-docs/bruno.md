---
recap: "Bruno collection structure and the mandatory Node.js sandbox switch for L2 requests — QuickJS lacks crypto/fs/path."
keywords: [Bruno, QuickJS, Node.js sandbox, unsafe, --sandbox unsafe, Developer mode, green shield, l2KeysDir, crypto module, fs module, path module, pre-request scripts, bru run, local environment, private_key_jwt, RFC 7523, L1, client_secret, placerL1ClientId, placerL1ClientSecret, m2m_l1_client_secrets, ADR 0004]
---

# Bruno collection

Open `bruno/` in Bruno and select the `local` environment.

## Structure

| Folder | Requests |
|--------|----------|
| `auth/` | Discovery, JWKS, L2 tokens (placer/fulfiller), context tokens (placer+fulfiller with `authorization_details`), L1 debug token (placer) |
| `validation/` | Health check, validate token, mock FHIR endpoints, context token claims inspection |
| `negative/` | Wrong secret, garbage token, missing scope, context gate without context, expired assertion, wrong assertion `aud`, unknown `authorization_details` type, unsupported grant type |

Suggested order: `auth/` → `validation/` → `negative/`.

### auth/ sequence

| File | What it tests |
|------|---------------|
| `01-discovery.bru` | OIDC discovery endpoint |
| `02-jwks.bru` | AS public key set |
| `05-get-placer-token-context.bru` | Placer L2 + RFC 9396 `authorization_details` → `fhirContext` |
| `06-get-placer-token-l2.bru` | Placer L2 token request |
| `07-get-fulfiller-token-l2.bru` | Fulfiller L2 token request |
| `08-get-fulfiller-token-context.bru` | Canonical IG example: fulfiller L2 + `authorization_details` |
| `09-get-placer-token-l1.bru` | Placer L1 (`client_secret`) debug token — requires `config/hospitals-l1/hospital-a.yaml` + `terraform apply` |

### negative/ sequence

| File | Behaviour exercised |
|------|---------------------|
| `01-wrong-secret.bru` | `client_secret` against L2 client → 400 |
| `02-validate-garbage-token.bru` | Malformed token at `/validate` → 422 |
| `03-missing-scope.bru` | Default scope present (positive case of default scope) |
| `04-context-gate-without-context.bru` | L2 token without `fhirContext` → 403 on context-gated resource |
| `06-expired-client-assertion.bru` | Client assertion with `exp` in the past → 400 (RFC 7523 §3) |
| `07-wrong-assertion-aud.bru` | Client assertion `aud` pointing to wrong endpoint → 400 |
| `08-unknown-context-type.bru` | `authorization_details` with unknown type → token issued, no `fhirContext` |
| `09-unsupported-grant-type.bru` | `authorization_code` grant (IG is M2M only) → 400 |

## L2 sandbox mode — required

The L2 pre-request scripts (`06-get-placer-token-l2.bru`, `07-get-fulfiller-token-l2.bru`) use Node.js built-ins (`crypto`, `fs`, `path`) to sign the RFC 7523 client assertion locally.

Bruno's **default sandbox is QuickJS**, which does not expose these modules. L2 requests will fail with `Cannot find module crypto` unless you switch:

- **CLI:** always pass `--sandbox unsafe`
  ```sh
  bru run --env local --sandbox unsafe
  ```
- **Desktop:** click the **green shield icon** (top-right of the collection window) → *"Developer mode"*

The `unsafe` label is Bruno's terminology for "run scripts in Node.js instead of QuickJS." L1, validation, and negative requests do not use `require()` and work in either sandbox.

## Audience (`aud`)

All L2 token requests (`06`, `07`, `08`) get a constant ecosystem `aud` (the realm issuer URL) applied automatically — no `aud:` scope parameter is needed or supported. See [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

**Prerequisite**: Terraform must have been applied after the last commit. If you get 401/400 errors, re-run `docker compose up keycloak-config`.

## Key path

If Bruno cannot resolve the demo key path, set the `l2KeysDir` variable in `bruno/environments/local.bru` to the absolute path of `keys/`.

## L1 debug token (`09-get-placer-token-l1.bru`)

Exercises the opt-in L1 (`client_secret`) debug client from [ADR 0004](../docs/adr/0004-reinstate-l1-debug-client.md) — not the production path (see CLAUDE.md's "Production default is L2" rule). Needs `keycloak/config/hospitals-l1/hospital-a.yaml` to exist and `terraform apply` to have run; the client secret is Keycloak-generated (not a demo key in this repo), so fetch it with `terraform output -json m2m_l1_client_secrets` and set `placerL1ClientSecret` in the `local` environment. Unlike the L2 requests, no pre-request signing script is needed, so it works in either Bruno sandbox.
