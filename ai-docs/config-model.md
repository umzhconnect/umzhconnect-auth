---
recap: "YAML-driven config model — apps, grants, and fhir-servers YAML files that drive KC client generation via Terraform."
keywords: [config/apps, config/grants, config/fhir-servers.yaml, app_id, org_id, server_key, jwks_url, required_scopes, optional_scopes, fhir_server_key, grants, KC client naming, double-dash separator, validate-grants.py, onboarding, two-PR workflow, no default grants, ADR 0002, ADR 0003]
---

# Config model

All KC clients are generated from YAML files. No HCL changes are needed to add or revoke access — only YAML + `terraform apply`.

Full architecture: [`audience_architecture.md`](../audience_architecture.md).

## Directory layout

```
keycloak/config/
  fhir-servers.yaml          # network FHIR server registry (server key → URL)
  apps/
    {org_id}--{app_id}.yaml  # one file per application — identity + declared scopes
  grants/
    {server_key}.yaml        # one file per FHIR server — access rights granted per caller
```

## `fhir-servers.yaml`

Each key becomes a Keycloak client scope named `aud:<key>`. Terraform reads this in `audiences.tf`. Adding a new FHIR server = one new entry + `terraform apply`.

```yaml
servers:
  fhir-hospital-a-referral:
    url: "https://referral.hospital-a.example/fhir"
    description: "Hospital A — Referral FHIR server"
```

## `config/apps/{org_id}--{app_id}.yaml`

Identity and authentication config for a calling application. Contains no audience or scope grants.

```yaml
org_id: "hospital-b"
app_id: "lis"
org_display_name: "Hospital B"
app_display_name: "Laboratory Information System"
org_reference: "https://fhir.hospital-b.example/fhir/Organization/HospitalB"
role: "fulfiller"
tenant: "fulfiller"
jwks_url: "https://hospital-b.example/.well-known/jwks/lis.json"
required_scopes:
  - "system/Patient.r"
optional_scopes:
  - "system/Observation.r"
  - "system/Task.cru"
```

`required_scopes` and `optional_scopes` are for documentation and `validate-grants.py` validation only — Terraform does not read them. Nothing in this file is secret; `jwks_url` is a public HTTPS endpoint.

## `config/grants/{server_key}.yaml`

Owned by the org operating that FHIR server. Drives KC client generation — an app not listed here gets no KC client for this server and therefore no access.

```yaml
fhir_server_key: "fhir-hospital-a-referral"

grants:
  hospital-b--lis:             # {org_id}--{app_id} — matches app filename
    scopes:
      - "system/Patient.r"
      - "system/ServiceRequest.r"
      - "system/Task.cru"
```

No default grants — every entry is explicit. See [ADR 0003](../docs/adr/0003-no-default-grant-scopes.md).

## KC client naming

`{org_id}--{app_id}--{server_key}` — double-dash separator is unambiguous (org/app IDs use single dashes; KC client IDs allow `--`).

Example: `hospital-b--lis--fhir-hospital-a-referral`

## Onboarding a new application

1. Calling org adds `config/apps/{org_id}--{app_id}.yaml`.
2. Each target org that wants to grant access adds an entry to `config/grants/{server_key}.yaml`.
3. Run `scripts/validate-grants.py` to confirm required scopes are covered.
4. `terraform apply`.

PR diff: one app file + one or more grant files. No HCL changes needed.

## Onboarding a new FHIR server

Add one entry to `config/fhir-servers.yaml`, create `config/grants/{server_key}.yaml`, then `terraform apply`.

## Revoking access

Remove the app's entry from the target's `config/grants/{server_key}.yaml` and run `terraform apply`. The KC client is destroyed.

## validate-grants.py

`scripts/validate-grants.py` checks that every grant's scope set covers the app's `required_scopes` and that all referenced app keys exist in `config/apps/`. Run before `terraform apply` when changing grants.
