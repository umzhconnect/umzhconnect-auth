---
recap: "docker-compose stack — services, the KC_HOSTNAME_BACKCHANNEL_DYNAMIC split between internal and published URLs, and the jwks-server role."
keywords: [KC_HOSTNAME_BACKCHANNEL_DYNAMIC, keycloak:8080, localhost:8180, backchannel URL, published issuer, jwks-server, nginx, token-validator, keycloak-config, start-dev, production hardening, TF_VAR_keycloak_url, apisix, compose network]
---

# Infrastructure

## Services

| Service | URL (host) | Notes |
|---------|-----------|-------|
| `keycloak` | http://localhost:8180 | admin / admin; issuer `http://localhost:8180/realms/umzh-connect` |
| `keycloak-config` | — | One-shot Terraform apply; runs and exits |
| `jwks-server` | http://localhost:8085 | nginx serving demo L2 client JWKS files from `keys/` |
| `token-validator` | http://localhost:8086 | Mock resource server |

## KC_HOSTNAME_BACKCHANNEL_DYNAMIC

`KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` in `docker-compose.yml` lets in-network services (Terraform, token-validator) reach Keycloak at `http://keycloak:8080` while the published issuer remains `http://localhost:8180/realms/umzh-connect`.

This is why:
- `TF_VAR_keycloak_url` inside compose uses `http://keycloak:8080` (the backchannel address).
- Tokens still show `http://localhost:8180/realms/umzh-connect` in the `iss` claim.

When running Terraform directly on the host (outside compose): `TF_VAR_keycloak_url=http://localhost:8180`.

## jwks-server

Stands in for the sandbox's APISIX gateways, which publish client JWKS at `/jwks.json` on each party's external gateway. For drop-in sandbox use, override the Terraform variables:

```sh
TF_VAR_placer_l2_jwks_url=http://apisix-placer-external:9080/jwks.json \
TF_VAR_fulfiller_l2_jwks_url=http://apisix-fulfiller-external:9080/jwks.json \
terraform apply
```

## Dev-only flags

`start-dev` in `docker-compose.yml` disables all Keycloak production hardening. Always document this clearly and never use it in a production image. For production, the command becomes `start --optimized`.
