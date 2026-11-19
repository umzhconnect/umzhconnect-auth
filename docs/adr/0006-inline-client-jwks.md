# 0006 — Allow an inline client JWKS as an alternative to `jwks_url`

**Status:** Accepted
**Date:** 2026-11-19
**Authors:** Trifork

---

## Context

L2 clients authenticate with `private_key_jwt` (RFC 7523). Until now every L2
client registered its public key as a `jwks_url`. Keycloak fetches that URL
to verify each client assertion (`use.jwks.url` / `jwks.url`).

Some organisations can't easily publish a JWKS endpoint that Keycloak can
reach. Reasons include no public web presence for the integration, firewall
or proxy rules on outbound-facing hosts, and change processes for publishing
new endpoints. This is exactly the class of problem that led to the L1 debug
client ([ADR 0004](0004-reinstate-l1-debug-client.md)). But L1 is only for
debugging, and these organisations need a production path.

The IG doesn't require a URL. Its `security.md` ("Client authentication")
says each client "registers the **public key / JWKS** with the Authorization
Server at onboarding". SMART Backend Services likewise allows registering
either a JWKS URL or the JWK Set itself. Only the Authorization Server
verifies client assertions. Resource servers verify AS-signed access tokens,
not client keys. So the client's public key doesn't need to be published
anywhere else.

Keycloak supports this natively. With `use.jwks.url = false`,
`use.jwks.string = true` and `jwks.string` set to a JWK Set, the client
attribute stores the key set and no outbound fetch happens.

---

## Decision

An L2 client YAML sets **exactly one** of:

- `jwks_url` — hosted JWKS (default, unchanged), or
- `jwks` — the organisation's **public** JWK Set inlined as a YAML map
  (`keys: [...]`). Terraform `jsonencode`s it into the client's
  `jwks.string` attribute.

There is no separate mode flag. Which field is present decides the mode, so
there's nothing that can contradict it. `terraform_data.client_config_guard`
hard-fails the apply if:

1. an L2 client sets both or neither field,
2. the inline set isn't a non-empty `keys` list where every key has `kty`
   and `kid`, with unique `kid`s,
3. a JWK member name was decoded as a boolean. Terraform's `yamldecode`
   follows YAML 1.1, so an unquoted `n:` / `y:` key (the RSA modulus, the EC
   y-coordinate) becomes `false` / `true`. Member names must be quoted.
4. any key carries private or symmetric material (`d`, `p`, `q`, `dp`, `dq`,
   `qi`, `oth`, `k`). The YAML lives in git.

Ruled out:

- **Keycloak-generated client key pairs** (admin console "Generate new
  keys"). The AS would create and hand out the private key. That breaks the
  IG rule that each client generates its own key pair, and it gives up
  non-repudiation.
- **Hosting organisations' JWKS on an AS-side endpoint** (for example
  `jwks-server` in production) and still using `jwks_url`. It's another
  component to run and secure, and it adds nothing over storing the key on
  the client.
- **A JSON string field** instead of a YAML map. It needs escaping and is
  harder to review in diffs. The map is turned into the same JSON string by
  `jsonencode`.

---

## Consequences

- Organisations that can't host a JWKS can still be onboarded at L2. No L1
  fallback and no extra infrastructure are needed.
- **Key rotation becomes an operator task** for inline clients. With a URL,
  the organisation rotates on its own. With an inline JWKS, every rotation
  is a reviewed YAML change plus `terraform apply`. Zero-downtime rollover
  takes two steps: add the new key (new `kid`) next to the old one and
  apply, the organisation switches to the new key, then remove the old one
  and apply. Verified locally: Keycloak picks up an added or removed `kid`
  on the next apply without a restart.
- **Always use a new `kid` when replacing a key.** Keycloak caches client
  public keys by `kid`. Replacing the material under an existing `kid`
  isn't guaranteed to take effect right away.
- Public keys of onboarded organisations become part of the reviewed config
  (and of the image-baked `keycloak-config/` in the gitops repo). That's
  fine for public keys. The private-member guard makes sure only public
  keys end up there.
- No realm or token change. Tokens issued to inline-JWKS clients are
  indistinguishable from those issued to `jwks_url` clients, so sandbox
  parity is unaffected.
- Demo: `keycloak-config/clients/hospital_e-l2.yaml` + `keys/hospital_e-l2.key`,
  exercised by `bruno/auth/10-get-token-inline-jwks.bru` and
  `bruno/negative/20-inline-jwks-wrong-key.bru`.
