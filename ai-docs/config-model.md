---
recap: "YAML-driven config model — hospitals and scopes YAML files that drive KC client generation via Terraform."
keywords: [config/hospitals, config/scopes.yaml, org_id, fhir_url, allowed_targets, jwks_url, org_reference, default_scopes, optional_scopes, scopes.tf, clients.tf, resource_url, fhir-server client, audience mapper, onboarding, terraform apply, ADR 0002, ADR 0004]
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
org_id: "hospital-a"
org_display_name: "Hospital A"
org_reference: "https://fhir.hospital-a.example/fhir/Organization/HospitalA"
fhir_url: "https://fhir.hospital-a.example/fhir"
jwks_url: "https://hospital-a.example/.well-known/jwks.json"
allowed_targets:
  - "hospital-b"
  - "hospital-c"
```

| Field | Purpose |
|-------|---------|
| `org_id` | KC client ID (must match filename stem) |
| `org_display_name` | Human label shown in KC admin |
| `org_reference` | `Organization` FHIR reference — embedded in every token as `extensions.umzhconnect.organization_reference` |
| `fhir_url` | Base URL of this hospital's FHIR server, registered as `resource_url` on the companion `{org_id}-fhir-server` KC client (RFC 8707) |
| `jwks_url` | Public JWKS endpoint KC uses to verify `private_key_jwt` assertions |
| `allowed_targets` | Other hospital `org_id` values this client may mint audience-bound tokens for; omitted → no cross-hospital token flow |

Terraform creates two KC clients per file:
1. `{org_id}` — the M2M client (L2 `private_key_jwt`, service account enabled)
2. `{org_id}-fhir-server` — a no-flow resource-server registration that carries `resource_url = fhir_url` for RFC 8707 matching

`allowed_targets` drives the cross-hospital audience mapper cross-product (`clients.tf:audience_pairs`). Adding `hospital-b` here creates an `oidc-audience-mapper` on `{org_id}` that includes `hospital-b-fhir-server` in the token `aud` when `resource=<hospital-b fhir_url>` is sent.

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

1. Create `config/hospitals/{org_id}.yaml` with `fhir_url` and `allowed_targets`.
2. Add entries to `allowed_targets` in the source hospitals that should be able to target this one.
3. Run `terraform apply`.

The target hospital's `{org_id}-fhir-server` client must exist before KC can resolve audience mappers pointing to it, so onboard both sides before testing cross-hospital flows.

---

## Revoking access

To block a hospital from minting tokens for a target: remove the target from its `allowed_targets` list and run `terraform apply`. The audience mapper is destroyed; the hospital can no longer include that target's FHIR server in `aud`.

To decommission a hospital entirely: delete its `{org_id}.yaml` and remove it from all other hospitals' `allowed_targets`. Run `terraform apply`.
