# `keycloak-config/clients/*.yaml`

One file per hospital M2M client. `client_id` and `auth_level` in the file
content — not the filename or directory — are what Terraform reads to
decide which client to create and how; the filename is a documentation
convention only (recommended: name the file after `client_id`).

## L2 (`private_key_jwt`) — production default

```yaml
client_id: "hospital_a-l2"
client_name: "Hospital A"
organization_reference: "https://fhir.hospital_a.example/fhir/Organization/HospitalA"
fhir_url: "https://fhir.hospital_a.example/fhir"
jwks_url: "http://jwks-server/hospital_a-l2.jwks.json"
auth_level: "L2"
```

`auth_level` must be `"L2"`; Terraform fails the apply if it isn't.

## L1 (`client_secret`) — opt-in debug client

Provisions an **L1 (`client_secret`) debug client** for a hospital. See
[ADR 0004](../../../docs/adr/0004-reinstate-l1-debug-client.md).

Independent of any L2 file for the same hospital — a hospital may have an L1
file, an L2 file, both, or neither. There is no requirement that the L2 file
exist first: a hospital may start integration on L1 while debugging
connectivity (firewalls, routing, JWKS reachability) and move to L2 later.

```yaml
client_id: "hospital_a-l1"
client_name: "Hospital A"
organization_reference: "https://fhir.hospital_a.example/fhir/Organization/HospitalA"
fhir_url: "https://fhir.hospital_a.example/fhir"
auth_level: "L1"
```

`auth_level` must be `"L1"`; Terraform fails the apply if it isn't (a
copy-pasted `"L2"` file dropped in here, for example). No `jwks_url` — L1
authenticates with a Keycloak-generated `client_secret`, not
`private_key_jwt`. L1 clients are also gated by `var.allow_l1_debug_clients`
(default `false`) — an L1 file present without that opt-in is ignored (with
a warning), not provisioned.

To revoke access for either level: delete the file and `terraform apply`.

## `enabled` — optional, defaults to `true`

Both L1 and L2 files accept an optional `enabled: false` to temporarily
disable a client without deleting the file. Unlike deleting the file (which
destroys the KC client and, for L1, its `client_secret`), `enabled: false`
maps straight to Keycloak's own client-level enabled flag — the client,
its `client_id`, and (for L1) its `client_secret` are all preserved
untouched, and re-enabling is just flipping it back to `true` (or removing
the line) and re-applying.

```yaml
client_id: "hospital_a-l1"
...
auth_level: "L1"
enabled: false
```
