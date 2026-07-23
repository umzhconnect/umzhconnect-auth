# `config/clients-l1/*.yaml`

Provisions an **L1 (`client_secret`) debug client** for a hospital. See
[ADR 0004](../../../docs/adr/0004-reinstate-l1-debug-client.md).

Independent of `config/clients-l2/*.yaml` — a hospital may have an L1 file, an
L2 file, both, or neither. There is no requirement that the L2 file exist
first: a hospital may start integration on L1 while debugging connectivity
(firewalls, routing, JWKS reachability) and move to L2 later.

```yaml
client_id: "hospital_a-l1"
client_name: "Hospital A"
organization_reference: "https://fhir.hospital-a.example/fhir/Organization/HospitalA"
fhir_url: "https://fhir.hospital-a.example/fhir"
auth_level: "L1"
```

`client_id` and `auth_level` are read directly by Terraform — the filename is
a documentation convention only (recommended: name the file after
`client_id`, e.g. `hospital_a-l1.yaml`) and is never read or depended on.
`auth_level` must be `"L1"` for every file in this directory; Terraform fails
the apply if it isn't (a copy-pasted `"L2"` file dropped in here, for
example). No `jwks_url` — L1 authenticates with a Keycloak-generated
`client_secret`, not `private_key_jwt`.

To revoke L1 access: delete the file and `terraform apply`, same as revoking
a hospital's L2 access.
