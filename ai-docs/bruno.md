---
recap: "Bruno collection structure and the mandatory Node.js sandbox switch for L2 requests — QuickJS lacks crypto/fs/path."
keywords: [Bruno, QuickJS, Node.js sandbox, unsafe, --sandbox unsafe, Developer mode, green shield, l2KeysDir, crypto module, fs module, path module, pre-request scripts, bru run, local environment, private_key_jwt, RFC 7523, L1, client_secret, placerL1ClientId, placerL1ClientSecret, m2m_l1_client_secrets, ADR 0004, docs block, docs tab, folder docs, collection docs, jwks-server, jwksServerUrl, clientId, .well-known, hospital_a-l2.jwks.json, hosted JWKS, jwks.url, hospital_c, generateKeyPairSync, unreachable jwks_url]
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

## Hosted client JWKS (`03-client-hosted-jwks.bru`)

Fetches an L2 client's own public key set from `{{jwksServerUrl}}/.well-known/{{clientId}}.jwks.json` (the local `jwks-server` container, or the equivalent APISIX-style gateway URL in `dev`) — this is the `jwks.url` Keycloak fetches to verify that client's `private_key_jwt` assertions, not the AS's own signing keys (`02-jwks.bru` covers those). Hosted under `.well-known/` by convention, filed under a name matching the client's own `client_id`, not a role name — see `keys/README.md`. The `clientId` variable defaults to `hospital_a` (the placer); there's no per-role distinction on this request, unlike the token-acquisition requests which use separate `placerClientId`/`fulfillerClientId` variables — set `clientId: hospital_b` to fetch the fulfiller's instead. No sandbox requirement — it's a plain GET.

## Key path

If Bruno cannot resolve the demo key path, set the `l2KeysDir` variable in `bruno/environments/local.bru` to the absolute path of `keys/`.

## Hospital C: onboarded but unreachable jwks_url (`negative/10-unreachable-jwks-hospital_c.bru`)

`config/clients/hospital_c-l2.yaml` onboards a third demo hospital, but its `jwks_url` points at a real external host (`https://hospital_c.example/...`), not `jwks-server` — there's no matching `keys/hospital_c.key` in this repo. The pre-request script generates a throwaway RSA keypair with `crypto.generateKeyPairSync` (no file to read) purely to produce a syntactically valid assertion; the request still fails because Keycloak can't reach `hospital_c.example` to fetch/verify against in the first place.

## L1 debug token (`09-get-placer-token-l1.bru`)

Exercises the opt-in L1 (`client_secret`) debug client from [ADR 0004](../docs/adr/0004-reinstate-l1-debug-client.md) — not the production path (see CLAUDE.md's "Production default is L2" rule). Needs `keycloak/config/clients/hospital_a-l1.yaml` to exist and `terraform apply` to have run; the client secret is Keycloak-generated (not a demo key in this repo), so fetch it with `terraform output -json m2m_l1_client_secrets` and set `placerL1ClientSecret` in the `local` environment. Unlike the L2 requests, no pre-request signing script is needed, so it works in either Bruno sandbox.

## Keep `docs` blocks in sync

The `docs` blocks are the authoritative human-facing reference for the collection (see above) — they live in the `.bru` files, not in this doc, so they don't update themselves.

Whenever you edit the collection, update the relevant `docs` block in the same change:

- **Add/remove/rename a request** — update the owning folder's `docs` block (structure overview) and add/update that request's own `docs` block explaining what it does and why.
- **Change a request's behavior** (params, body, pre-request script, expected status/assertions) — update that request's `docs` block so it still matches what the request actually does.
- **Add/remove a folder** — update the collection root's `docs` block (structure overview) in the collection settings → Docs tab.
- **Change sandbox/environment requirements** (e.g. a new request needs `--sandbox unsafe`, or a new env variable) — update this file (`ai-docs/bruno.md`) too, since it covers mechanics that don't fit in a single request's `docs` block.

Edit `docs` blocks via Bruno's UI (request/folder/collection settings → Docs tab) or directly in the `.bru` file's `docs { ... }` block — either is fine, but don't let the two drift.

Bruno's built-in md renderer currently treats every `\n` as a new paragraph (no soft-wrap within a paragraph) — avoid unnecessary `\n` inside `docs` blocks, or lines that should read as one flowing paragraph will render as separate, oddly-spaced ones.
