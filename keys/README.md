# Level 2 demo client keys

**Demo material only — never use these keys outside local development.** The
private key *material* is copied verbatim from the public
[umzhconnect-sandbox](https://github.com/umzhconnect/umzhconnect-sandbox) repo
(`services/keys/`, Apache-2.0) so tokens are cryptographically interchangeable
with the sandbox — only the filenames and `kid` here have been renamed to
match this repo's hospital naming (`hospital_a-l2`, `hospital_b-l2`) instead of the
sandbox's `placer-l2` / `fulfiller-l2` role names. These filenames are
independent of KC `client_id` (which is `hospital_a-l2` etc., see
[ai-docs/config-model.md](../ai-docs/config-model.md)) — the key/JWKS pair
just needs to match the `jwks_url` configured for that client.

| File | Purpose |
|------|---------|
| `hospital_a-l2.key` / `hospital_b-l2.key` | RSA-2048 private keys the Level 2 clients use to sign `private_key_jwt` client assertions (RFC 7523) |
| `.well-known/hospital_a-l2.jwks.json` / `.well-known/hospital_b-l2.jwks.json` | Matching public JWKS; Keycloak fetches these via each client's `jwks.url` to verify assertions |

Public JWKS live under `.well-known/` so they can be served at the
conventional `/.well-known/{hospital_name}.jwks.json` path. The private `.key`
files stay directly under `keys/`, outside `.well-known/`, so the split
between what's public and what's private is a plain directory boundary — see
`jwks-server/Dockerfile`, which only copies `keys/.well-known/`.

In this stack the JWKS files are served by the `jwks-server` compose service
(nginx) at `http://localhost:8085/.well-known/{hospital_name}.jwks.json` —
standing in for the sandbox's APISIX gateways, which publish them at
`/jwks.json` (no `.well-known/`) on each party's external gateway.

The JWT `kid` header of a client assertion must match the `kid` in the JWKS
(`hospital_a-l2` / `hospital_b-l2`).

Regenerate a pair with:

```sh
openssl genrsa -out hospital_a-l2.key 2048
# then rebuild the JWKS (n/e from the public key, kid=hospital_a-l2, alg=RS256)
# and place it at .well-known/hospital_a-l2.jwks.json
```
