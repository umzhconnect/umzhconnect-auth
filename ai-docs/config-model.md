---
recap: "YAML-driven config model — hospitals and scopes YAML files that drive KC client generation via Terraform, plus the independent hospitals-l1 debug-client directory."
keywords: [config/hospitals, config/hospitals-l1, config/scopes.yaml, org_id, fhir_url, jwks_url, org_reference, default_scopes, optional_scopes, scopes.tf, clients.tf, ecosystem-audience-mapper, auth_level, onboarding, terraform apply, ADR 0002, ADR 0003, ADR 0004]
---

# Config model

All KC clients are generated from YAML files. No HCL changes are needed to add or revoke access — only YAML + `terraform apply`.

## Directory layout

```
keycloak/config/
  scopes.yaml              # all custom client scopes for the realm
  hospitals/
    {org_id}.yaml          # one file per onboarded hospital (L2, default)
  hospitals-l1/
    {org_id}.yaml          # optional L1 debug client, independent of hospitals/
```

---

## `config/hospitals/{org_id}.yaml`

Identity, authentication, and audience config for one hospital. A hospital with no file here has no KC client and cannot obtain tokens.

```yaml
org_id: "hospital-b"
org_display_name: "Hospital B"
org_reference: "https://fhir.hospital-b.example/fhir/Organization/HospitalB"
fhir_url: "https://fhir.hospital-b.example/fhir"
jwks_url: "https://hospital-b.example/.well-known/hospital-b.jwks.json"
```

| Field | Purpose |
|-------|---------|
| `org_id` | KC client ID (must match filename stem) |
| `org_display_name` | Human label shown in KC admin |
| `org_reference` | `Organization` FHIR reference — embedded in every token as `extensions.umzhconnect.organization_reference` |
| `fhir_url` | Base URL of this hospital's FHIR server. Not currently written into `aud` — see [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md) (`aud` is a constant ecosystem value, not per-hospital) |
| `jwks_url` | Public JWKS endpoint KC uses to verify `private_key_jwt` assertions. By convention, hosted under `/.well-known/{org_id}.jwks.json` — see the local demo setup in `keys/README.md` |

Terraform creates one KC client per file:
- `{org_id}` — the M2M client (L2 `private_key_jwt`, service account enabled)

There is no per-hospital inbound allow-list. Every M2M client's tokens carry the same constant ecosystem `aud`; any FHIR server in the realm accepts any client's token and is responsible for its own authorization. See [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

---

## `config/hospitals-l1/{org_id}.yaml` — optional L1 debug client

An **opt-in, per-hospital** L1 (`client_secret`) debug client, independent of `config/hospitals/{org_id}.yaml`. See [ADR 0004](../docs/adr/0004-reinstate-l1-debug-client.md) and [the directory's own README](../keycloak/config/hospitals-l1/README.md) for the field schema.

```yaml
org_display_name: "Hospital A"
org_reference: "https://fhir.hospital-a.example/fhir/Organization/HospitalA"
fhir_url: "https://fhir.hospital-a.example/fhir"
reason: "Firewall/JWKS connectivity debugging"
requested_by: "Hospital A IT"
requested_date: "2026-07-16"
```

Key points:
- **Independent of the L2 file for the same `org_id`** — a hospital may have an L1 file, an L2 file, both, or neither. There is no requirement that the L2 file exist first.
- No `jwks_url` — authenticates with a Keycloak-generated `client_secret`, not `private_key_jwt`.
- Terraform creates `{org_id}--l1` with the same mapper set as the L2 client (`client-id-mapper`, `org-reference-mapper`, `fhir-context-mapper`, `ecosystem-audience-mapper`) plus an `auth_level` claim (`"L1"` vs `"L2"` on the primary client) so resource servers can distinguish them.
- Secret handling is deliberately relaxed relative to real production secrets — see ADR 0004.
- Revoke the same way as a hospital: delete the file, `terraform apply`.

---

## `config/scopes.yaml`

All custom SMART Backend Services client scopes for the realm. Terraform reads this in `scopes.tf` to create scopes and assign defaults to every hospital M2M client.

```yaml
default_scopes:
  - name: "system/Task.cru"
    description: "SMART system scope: create/read/update Tasks"
  # ... (see the file for the full list)

optional_scopes:
  - name: "smart-task-write"
    description: "SMART on FHIR: Create/update tasks"
  # ...
```

`default_scopes` are always present in issued tokens. `optional_scopes` are registered in KC so callers may request them explicitly via the `scope` parameter; they are not sent unless requested.

To add a scope: add an entry to `config/scopes.yaml` and run `terraform apply`. To remove one: remove the entry — Terraform will destroy the scope and its client assignments.

---

## Onboarding a hospital

1. Create `config/hospitals/{org_id}.yaml` with `org_id`, `org_display_name`, `org_reference`, `fhir_url`, and `jwks_url`.
2. Run `terraform apply`.

---

## Revoking access

To decommission a hospital entirely: delete its `{org_id}.yaml` and run `terraform apply`. There is no allow-list to clean up elsewhere.
