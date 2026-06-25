---
recap: "Audience claim design — RFC 8707 resource indicators implemented via KC experimental feature; aud is now bound to the target FHIR server URL when resource= is supplied."
keywords: [aud claim, audience, ADR 0002, ADR 0003, ADR 0004, RFC 8707, resource parameter, resource_url, resource-indicators, fhir_url, allowed_targets, keycloak/keycloak#50251, use_refresh_token, invalid_target, one client per hospital, fhir-server client, audience mapper, cross_hospital, clients.tf]
---

# Audience (`aud`) claim design

**Status:** Implemented — RFC 8707 resource indicators active via KC experimental feature. See [ADR 0004](../docs/adr/0004-rfc8707-resource-indicators.md).

---

## Current implementation

### Hospital clients (`{org_id}`)

One Keycloak client per hospital, L2 (`private_key_jwt`) only. Declared in `config/hospitals/{org_id}.yaml`.

### FHIR resource-server registrations (`{org_id}-fhir-server`)

One additional KC client per hospital whose only purpose is to register `fhir_url` as a known `resource_url`. No flows, no service account — KC uses these to resolve and validate the `resource=` parameter.

### Token request flow

```
POST /realms/umzh-connect/protocol/openid-connect/token
  grant_type=client_credentials
  client_id=hospital-a
  client_assertion=<JWT>
  client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
  resource=https://fhir.hospital-b.example/fhir
```

KC resolves `resource=` against registered `resource_url` values. If it matches a client that `hospital-a` has an audience mapper for, the token `aud` is restricted to `hospital-b-fhir-server`. Unknown URIs → `invalid_target`.

### Explicit allow-list

`allowed_targets` in each hospital YAML controls which audience mappers are created. A hospital with no entry in `allowed_targets` of the source hospital cannot receive a token scoped to it.

```yaml
# hospital-a.yaml
fhir_url: "https://fhir.hospital-a.example/fhir"
allowed_targets:
  - "hospital-b"
  - "hospital-c"
```

Terraform (`clients.tf`) derives the cross-product `audience_pairs` local from `allowed_targets` and creates one `keycloak_openid_audience_protocol_mapper` per pair.

### KC bug workaround

`client_credentials.use_refresh_token = true` is set on all M2M clients. Required to avoid an NPE in KC when `resource-indicators` is active (keycloak/keycloak#50251).

---

## Feature flag

The `resource-indicators` KC experimental feature is enabled at build time:

```dockerfile
RUN /opt/keycloak/bin/kc.sh build --features=resource-indicators
```

And at dev runtime:

```yaml
command: start-dev --features=resource-indicators
```

---

## Adding a hospital

1. Create `config/hospitals/{org_id}.yaml` with `fhir_url` and `allowed_targets`.
2. Run `terraform apply` — KC creates the M2M client, the fhir-server client, and all audience mappers declared in `allowed_targets`.
3. Target hospitals listed in `allowed_targets` must themselves be onboarded (their `{org_id}-fhir-server` client must exist for the mapper to resolve).

---

## Prior design — superseded

### D1-via-YAML (before ADR 0002)
One KC client per (org, app, target FHIR server). Replaced by ADR 0002 (one client per hospital) when UMZH confirmed per-server granularity was premature.

### Deferred audience (ADR 0003, before ADR 0004)
`aud` defaulted to the KC client ID; no FHIR-server binding. Superseded by ADR 0004 once Michael (mrunibe) demonstrated the `resource-indicators` experimental feature working on KC 26.6.1 in umzhconnect-sandbox#31.

---

## Next milestone

Scope enforcement at the AS level is still deferred to the Policy Server milestone. When that arrives, layer per-(caller, target) scope grants on top of the existing audience binding.
