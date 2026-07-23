---
recap: "YAML-driven config model — client_id-keyed config files under config/clients-l2/ and config/clients-l1/ (plus config/scopes.yaml) that drive KC client generation via Terraform. Filenames are a convention only; client_id and auth_level in the file content are what Terraform actually reads."
keywords: [config/clients-l2, config/clients-l1, config/scopes.yaml, client_id, auth_level, fhir_url, jwks_url, organization_reference, client_name, default_scopes, optional_scopes, scopes.tf, clients.tf, ecosystem-audience-mapper, onboarding, terraform apply, lifecycle precondition, ADR 0002, ADR 0003, ADR 0004]
---

# Config model

All KC clients are generated from YAML files. No HCL changes are needed to add or revoke access — only YAML + `terraform apply`.

## Directory layout

```
keycloak/config/
  scopes.yaml              # all custom client scopes for the realm
  clients-l2/
    *.yaml                 # one file per L2 (private_key_jwt) client, default
  clients-l1/
    *.yaml                 # optional L1 (client_secret) debug client, independent of clients-l2/
```

**Filenames are a documentation convention only, never read by Terraform.** Every file carries its own `client_id`, and Terraform builds its `for_each` maps by reading each file's `client_id` field, not the filename. Recommended convention: name the file after its `client_id` (e.g. `hospital_a-l2.yaml`), but nothing enforces this — Terraform would happily provision from `foo.yaml` if that file's `client_id` field said `hospital_a-l2`. A duplicate `client_id` value across two files in the same directory fails the `terraform apply` with Terraform's own "Duplicate object key" error.

`client_id` naming convention: underscores within the hospital name, hyphen before the level suffix — `{hospital_name}-{l1|l2}`, e.g. `hospital_a-l2`, `hospital_a-l1`. Every client's level is explicit in its own `client_id`; there's no suffix concatenation in Terraform.

---

## `config/clients-l2/*.yaml`

Identity, authentication, and audience config for one hospital's L2 client. A hospital with no file here has no L2 KC client and cannot obtain tokens.

```yaml
client_id: "hospital_b-l2"
client_name: "Hospital B"
organization_reference: "https://fhir.hospital-b.example/fhir/Organization/HospitalB"
fhir_url: "https://fhir.hospital-b.example/fhir"
jwks_url: "https://hospital-b.example/.well-known/hospital-b.jwks.json"
auth_level: "L2"
```

| Field | Purpose |
|-------|---------|
| `client_id` | KC client ID — the only identity Terraform reads; independent of the filename |
| `client_name` | Human label shown in KC admin |
| `organization_reference` | `Organization` FHIR reference — embedded in every token as `extensions.umzhconnect.organization_reference` |
| `fhir_url` | Base URL of this hospital's FHIR server. Not currently written into `aud` — see [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md) (`aud` is a constant ecosystem value, not per-hospital) |
| `jwks_url` | Public JWKS endpoint KC uses to verify `private_key_jwt` assertions. Independent of `client_id` — see the local demo setup in `keys/README.md` |
| `auth_level` | Must be `"L2"` for every file in this directory. Written straight through into the `extensions.umzhconnect.auth_level` claim (no case conversion). A `lifecycle.precondition` on the client resource (`clients.tf`) hard-fails `terraform apply` if a file's `auth_level` doesn't match its directory — catches a copy-pasted L1 file landing here by mistake |

Terraform creates one KC client per file:
- `{client_id}` — the M2M client (L2 `private_key_jwt`, service account enabled)

There is no per-hospital inbound allow-list. Every M2M client's tokens carry the same constant ecosystem `aud`; any FHIR server in the realm accepts any client's token and is responsible for its own authorization. See [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

---

## `config/clients-l1/*.yaml` — optional L1 debug client

An **opt-in, per-hospital** L1 (`client_secret`) debug client, independent of any `config/clients-l2/*.yaml` file for the same hospital. See [ADR 0004](../docs/adr/0004-reinstate-l1-debug-client.md) and [the directory's own README](../keycloak/config/clients-l1/README.md).

```yaml
client_id: "hospital_a-l1"
client_name: "Hospital A"
organization_reference: "https://fhir.hospital-a.example/fhir/Organization/HospitalA"
fhir_url: "https://fhir.hospital-a.example/fhir"
auth_level: "L1"
```

Key points:
- **Independent of the L2 file for the same hospital** — a hospital may have an L1 file, an L2 file, both, or neither. There is no requirement that the L2 file exist first.
- No `jwks_url` — authenticates with a Keycloak-generated `client_secret`, not `private_key_jwt`.
- `auth_level` must be `"L1"` for every file in this directory; same `lifecycle.precondition` enforcement as `clients-l2/`.
- No audit-metadata fields (`reason`/`requested_by`/`requested_date` from an earlier revision of this schema have been dropped).
- Terraform creates `{client_id}` with the same mapper set as an L2 client (`client-id-mapper`, `org-reference-mapper`, `fhir-context-mapper`, `ecosystem-audience-mapper`, `auth-level-mapper`) so resource servers can distinguish them via the `auth_level` claim.
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

1. Create `config/clients-l2/{client_id}.yaml` with `client_id`, `client_name`, `organization_reference`, `fhir_url`, `jwks_url`, and `auth_level: "L2"`.
2. Run `terraform apply`.

---

## Revoking access

To decommission a hospital entirely: delete its `config/clients-l2/*.yaml` file and run `terraform apply`. There is no allow-list to clean up elsewhere.
