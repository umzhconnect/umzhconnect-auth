---
recap: "Bruno collection structure and the mandatory Node.js sandbox switch for L2 requests — QuickJS lacks crypto/fs/path."
keywords: [Bruno, QuickJS, Node.js sandbox, unsafe, --sandbox unsafe, Developer mode, green shield, l2KeysDir, crypto module, fs module, path module, pre-request scripts, bru run, local environment, private_key_jwt, RFC 7523]
---

# Bruno collection

Open `bruno/` in Bruno and select the `local` environment.

## Structure

| Folder | Requests |
|--------|----------|
| `auth/` | Discovery, JWKS, L1 tokens (placer/fulfiller), L2 tokens (placer/fulfiller), context token |
| `validation/` | Health check, validate token, mock FHIR endpoints |
| `negative/` | Wrong secret, garbage token, missing scope, context gate without context |

Suggested order: `auth/` → `validation/` → `negative/`.

## L2 sandbox mode — required

The L2 pre-request scripts (`06-get-placer-token-l2.bru`, `07-get-fulfiller-token-l2.bru`) use Node.js built-ins (`crypto`, `fs`, `path`) to sign the RFC 7523 client assertion locally.

Bruno's **default sandbox is QuickJS**, which does not expose these modules. L2 requests will fail with `Cannot find module crypto` unless you switch:

- **CLI:** always pass `--sandbox unsafe`
  ```sh
  bru run --env local --sandbox unsafe
  ```
- **Desktop:** click the **green shield icon** (top-right of the collection window) → *"Developer mode"*

The `unsafe` label is Bruno's terminology for "run scripts in Node.js instead of QuickJS." L1, validation, and negative requests do not use `require()` and work in either sandbox.

## D2 — `aud:` scope parameter

Requests `06` and `07` include `aud:hospital-b` / `aud:hospital-a` in the `scope` field to demonstrate cross-hospital audience binding (D2, ADR 0005):

- Request `06` (hospital-a placer): `scope=... aud:hospital-b` → token `aud` = `https://fhir.hospital-b.example/fhir`
- Request `07` (hospital-b fulfiller): `scope=... aud:hospital-a` → token `aud` = `https://fhir.hospital-a.example/fhir`

KC grants the `aud:` optional scope (only if it is assigned to the calling client via `allowed_targets`) and fires the audience mapper. An unknown or unauthorized `aud:` scope returns `invalid_scope`.

**Prerequisite**: Terraform must have been applied after the last commit. If you get 401/400 errors, re-run `docker compose up keycloak-config`.

## Key path

If Bruno cannot resolve the demo key path, set the `l2KeysDir` variable in `bruno/environments/local.bru` to the absolute path of `keys/`.
