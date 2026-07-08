---
recap: "YAML-driven config model — hospitals and scopes YAML files that drive KC client generation via Terraform."
keywords: [config/hospitals, config/scopes.yaml, org_id, fhir_url, allowed_clients, jwks_url, org_reference, default_scopes, optional_scopes, scopes.tf, clients.tf, audience mapper, onboarding, terraform apply, ADR 0002, ADR 0003]
---

# Config model

All KC clients are generated from YAML files. No HCL changes are needed to add or revoke access — only YAML + `terraform apply`.

## Directory layout

```
keycloak/config/
  scopes.yaml              # all custom client scopes for the realm
  hospitals/
    {org_id}.yaml          # one file per onboarded hospital
```

---

## `config/hospitals/{org_id}.yaml`

Identity, authentication, and audience config for one hospital. A hospital with no file here has no KC client and cannot obtain tokens.

```yaml
org_id: "hospital-b"
org_display_name: "Hospital B"
org_reference: "https://fhir.hospital-b.example/fhir/Organization/HospitalB"
fhir_url: "https://fhir.hospital-b.example/fhir"
jwks_url: "https://hospital-b.example/.well-known/jwks.json"
allowed_clients:
  - "hospital-a"
  - "hospital-c"
```

| Field | Purpose |
|-------|---------|
| `org_id` | KC client ID (must match filename stem) |
| `org_display_name` | Human label shown in KC admin |
| `org_reference` | `Organization` FHIR reference — embedded in every token as `extensions.umzhconnect.organization_reference` |
| `fhir_url` | Base URL of this hospital's FHIR server; written into the token `aud` via the `aud:{org_id}` scope's audience mapper |
| `jwks_url` | Public JWKS endpoint KC uses to verify `private_key_jwt` assertions |
| `allowed_clients` | Hospital `org_id` values that may request a token with this hospital as audience (via `scope=aud:{this_org_id}`); omitted → no client may target this hospital |

Terraform creates one KC client per file:
- `{org_id}` — the M2M client (L2 `private_key_jwt`, service account enabled)

`allowed_clients` drives which M2M clients receive `aud:{org_id}` as an optional scope. Terraform (`scopes.tf`) iterates all hospitals; for each hospital Y, any client X that appears in Y's `allowed_clients` gets `aud:Y` added to its optional scope list. Requesting `scope=aud:hospital-b` from a client not in `hospital-b.allowed_clients` returns `invalid_scope`.

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

1. Create `config/hospitals/{org_id}.yaml` with `fhir_url`, `jwks_url`, and `allowed_clients` (the hospitals permitted to request tokens targeting the new hospital).
2. To allow the new hospital to target existing ones, add its `org_id` to `allowed_clients` in those hospitals' YAML files.
3. Run `terraform apply`.

---

## Revoking access

To block a client from targeting a hospital: remove the client's `org_id` from the target hospital's `allowed_clients` and run `terraform apply`. The optional scope assignment is removed; the client can no longer request `aud:{target}`.

To decommission a hospital entirely: delete its `{org_id}.yaml` and remove its `org_id` from all other hospitals' `allowed_clients`. Run `terraform apply`.
