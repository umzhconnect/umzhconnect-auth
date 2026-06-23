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

## Key path

If Bruno cannot resolve the demo key path, set the `l2KeysDir` variable in `bruno/environments/local.bru` to the absolute path of `keys/`.
