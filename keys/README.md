# Level 2 demo client keys

**Demo material only — never use these keys outside local development.** The
private keys are intentionally committed; they are copied verbatim from the
public [umzhconnect-sandbox](https://github.com/umzhconnect/umzhconnect-sandbox)
repo (`services/keys/`, Apache-2.0) so tokens and clients are interchangeable
with the sandbox.

| File | Purpose |
|------|---------|
| `placer-l2.key` / `fulfiller-l2.key` | RSA-2048 private keys the Level 2 clients use to sign `private_key_jwt` client assertions (RFC 7523) |
| `placer-l2.jwks.json` / `fulfiller-l2.jwks.json` | Matching public JWKS; Keycloak fetches these via each client's `jwks.url` to verify assertions |

In this stack the JWKS files are served by the `jwks-server` compose service
(nginx) at `http://localhost:8085/<name>.jwks.json` — standing in for the
sandbox's APISIX gateways, which publish them at `/jwks.json` on each party's
external gateway.

The JWT `kid` header of a client assertion must match the `kid` in the JWKS
(`placer-l2` / `fulfiller-l2`).

Regenerate a pair with:

```sh
openssl genrsa -out placer-l2.key 2048
# then rebuild the JWKS (n/e from the public key, kid=placer-l2, alg=RS256)
```
