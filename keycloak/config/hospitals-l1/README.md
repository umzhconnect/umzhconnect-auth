# `config/hospitals-l1/{org_id}.yaml`

Provisions an **L1 (`client_secret`) debug client** for a hospital, KC client
ID `{org_id}--l1`. See [ADR 0004](../../../docs/adr/0004-reinstate-l1-debug-client.md).

Independent of `config/hospitals/{org_id}.yaml` — a hospital may have an L1
file, an L2 file, both, or neither. There is no requirement that the L2 file
exist first: a hospital may start integration on L1 while debugging
connectivity (firewalls, routing, JWKS reachability) and move to L2 later.

```yaml
org_display_name: "Hospital A"
org_reference: "https://fhir.hospital-a.example/fhir/Organization/HospitalA"
fhir_url: "https://fhir.hospital-a.example/fhir"
reason: "Firewall/JWKS connectivity debugging"
requested_by: "Hospital A IT"
requested_date: "2026-07-16"
```

No `jwks_url` — L1 authenticates with a Keycloak-generated `client_secret`,
not `private_key_jwt`. `reason`/`requested_by`/`requested_date` are audit
metadata only (not read by Terraform); every field but `org_display_name`
and `org_reference` is optional in practice but should be filled in for
traceability, since L1 is meant to be an explicit, tracked exception rather
than a default.

To revoke L1 access: delete the file and `terraform apply`, same as revoking
a hospital's L2 access.
