---
recap: "Bruno collection structure and the mandatory Node.js sandbox switch for L2 requests — QuickJS lacks crypto/fs/path."
keywords: [Bruno, QuickJS, Node.js sandbox, unsafe, --sandbox unsafe, Developer mode, green shield, l2KeysDir, crypto module, fs module, path module, pre-request scripts, bru run, local environment, private_key_jwt, RFC 7523, L1, client_secret, placerL1ClientId, placerL1ClientSecret, m2m_l1_client_secrets, ADR 0004]
---

# Bruno collection

Open `bruno/` in Bruno and select the `local` environment.

Every request has a `docs` block (visible in Bruno's right-hand panel, and
in `bru run` output) explaining what it does and why. The collection root
and each folder (`auth/`, `validation/`, `negative/`) also carry their own
`docs` block (collection/folder settings → Docs tab) with the structure
overview and per-folder purpose — that's the authoritative human-facing
reference now; this file only covers what doesn't fit there (sandbox setup
mechanics, environment variable gotchas).

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
