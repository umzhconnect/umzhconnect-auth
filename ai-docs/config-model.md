---
recap: "YAML-driven config model — client_id-keyed config files under config/clients/ (plus config/scopes.yaml) that drive KC client generation via Terraform. Whether a file is L1 or L2 is determined by its own auth_level field, not by directory. Filenames are a convention only; client_id and auth_level in the file content are what Terraform actually reads."
keywords: [config/clients, config/scopes.yaml, client_id, auth_level, enabled, fhir_url, jwks_url, organization_reference, client_name, optional_scopes, least privilege per request, scopes.tf, clients.tf, ecosystem-audience-mapper, onboarding, terraform apply, terraform_data client_config_guard, lifecycle precondition, ADR 0002, ADR 0003, ADR 0004]
---

# Config model

All KC clients are generated from YAML files. No HCL changes are needed to add or revoke access — only YAML + `terraform apply`.

## Directory layout

```
keycloak/config/
  scopes.yaml              # all custom client scopes for the realm
  clients/
    *.yaml                 # one file per client — L1 or L2, per the file's own auth_level field
```

**Filenames are a documentation convention only, never read by Terraform.** Every file carries its own `client_id` and `auth_level`, and Terraform builds its `for_each` maps by reading those fields, not the filename or which directory the file lives in — all client files, both L1 and L2, live together in `config/clients/`. Recommended convention: name the file after its `client_id` (e.g. `hospital_a-l2.yaml`), but nothing enforces this — Terraform would happily provision from `foo.yaml` if that file's `client_id` field said `hospital_a-l2`. A duplicate `client_id` value across two files hard-fails `terraform apply` with a `terraform_data.client_config_guard` precondition error naming the offending `client_id` (see below) — not Terraform's generic "Duplicate object key" error.

`client_id` naming convention: underscores within the hospital name, hyphen before the level suffix — `{hospital_name}-{l1|l2}`, e.g. `hospital_a-l2`, `hospital_a-l1`. Every client's level is explicit in its own `client_id` and `auth_level` field; there's no suffix concatenation in Terraform.

Terraform reads every file in `config/clients/` into `local.clients_by_id` (keyed by `client_id`), then splits it by each file's own `auth_level` field: `local.clients_l2` (`auth_level: "L2"`) and `local.clients_l1_all` (`auth_level: "L1"`). Two repo-wide invariants are enforced as `lifecycle.precondition` blocks on a no-op `resource "terraform_data" "client_config_guard"` (`clients.tf`) — a resource precondition hard-fails `terraform apply`, unlike a `check` block assertion, which only warns:
- No two files may share a `client_id`.
- Every file's `auth_level` must be `"L1"` or `"L2"` — a typo'd value would otherwise silently match neither filter and be ignored with no error.

---

## `config/clients/*.yaml` — L2 (default) client fields

Identity, authentication, and audience config for one hospital's L2 client. A hospital with no L2 file has no L2 KC client and cannot obtain tokens.

```yaml
client_id: "hospital_b-l2"
client_name: "Hospital B"
organization_reference: "https://fhir.hospital_b.example/fhir/Organization/HospitalB"
fhir_url: "https://fhir.hospital_b.example/fhir"
jwks_url: "https://hospital_b.example/.well-known/hospital_b-l2.jwks.json"
auth_level: "L2"
```

| Field | Purpose |
|-------|---------|
| `client_id` | KC client ID — the only identity Terraform reads; independent of the filename |
| `client_name` | Human label shown in KC admin |
| `organization_reference` | `Organization` FHIR reference — embedded in every token as `extensions.umzhconnect.organization_reference` |
| `fhir_url` | Base URL of this hospital's FHIR server. Not currently written into `aud` — see [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md) (`aud` is a constant ecosystem value, not per-hospital) |
| `jwks_url` | Public JWKS endpoint KC uses to verify `private_key_jwt` assertions. Independent of `client_id` — see the local demo setup in `keys/README.md` |
| `auth_level` | Must be `"L2"` for an L2 file. Written straight through into the `extensions.umzhconnect.auth_level` claim (no case conversion). This field (not the directory or filename) is what Terraform uses to route the file into `local.clients_l2`; the `terraform_data.client_config_guard` precondition (`clients.tf`) hard-fails `terraform apply` if any file's `auth_level` is neither `"L1"` nor `"L2"` |
| `enabled` | Optional, defaults to `true` if absent. Maps straight to KC's client-level `enabled` flag (`try(each.value.enabled, true)` in `clients.tf`) — distinct from `access_type`/`client_authenticator_type`. Set `enabled: false` to temporarily block a client from obtaining tokens without deleting the file or touching its credentials; flip back to `true` (or remove the line) to re-enable |

Terraform creates one KC client per file:
- `{client_id}` — the M2M client (L2 `private_key_jwt`, service account enabled)

There is no per-hospital inbound allow-list. Every M2M client's tokens carry the same constant ecosystem `aud`; any FHIR server in the realm accepts any client's token and is responsible for its own authorization. See [ADR 0003](../docs/adr/0003-constant-ecosystem-audience.md).

---

## `config/clients/*.yaml` — L1 debug client fields

An **opt-in, per-hospital** L1 (`client_secret`) debug client, defined by a file in the same `config/clients/` directory with `auth_level: "L1"`, independent of any L2 file for the same hospital. See [ADR 0004](../docs/adr/0004-reinstate-l1-debug-client.md) and [the directory's own README](../keycloak/config/clients/README.md).

```yaml
client_id: "hospital_a-l1"
client_name: "Hospital A"
organization_reference: "https://fhir.hospital_a.example/fhir/Organization/HospitalA"
fhir_url: "https://fhir.hospital_a.example/fhir"
auth_level: "L1"
```

Key points:
- **Independent of the L2 file for the same hospital** — a hospital may have an L1 file, an L2 file, both, or neither. There is no requirement that the L2 file exist first.
- No `jwks_url` — authenticates with a Keycloak-generated `client_secret`, not `private_key_jwt`.
- `auth_level` must be `"L1"` — this is what routes the file into `local.clients_l1_all`/`local.clients_l1` rather than `local.clients_l2`; the same `terraform_data.client_config_guard` enforcement applies repo-wide (see the directory layout section above).
- No audit-metadata fields (`reason`/`requested_by`/`requested_date` from an earlier revision of this schema have been dropped).
- `enabled` (optional, defaults to `true`) works the same as on L2 files — see the L2 field table above. For L1 in particular this preserves the Keycloak-generated `client_secret` across a temporary disable, where deleting the file would destroy it.
- Terraform creates `{client_id}` with the same mapper set as an L2 client (`client-id-mapper`, `org-reference-mapper`, `fhir-context-mapper`, `ecosystem-audience-mapper`, `auth-level-mapper`) so resource servers can distinguish them via the `auth_level` claim.
- Secret handling is deliberately relaxed relative to real production secrets — see ADR 0004.
- Revoke the same way as a hospital: delete the file, `terraform apply`.

---

## `config/scopes.yaml`

All custom SMART Backend Services client scopes for the realm. Terraform reads this in `scopes.tf` to create scopes and register every one of them as an optional scope on every hospital M2M client.

```yaml
scopes:
  - name: "system/Task.crus"
    description: "SMART system scope: create/read/update/search Tasks"
  # ... (see the file for the full list)
```

Every scope is optional — none is ever included by default. A caller only receives the scopes it explicitly requests via the token request's `scope` parameter, regardless of what other scopes it's entitled to request. `default_scopes` on the KC client resources is pinned to an empty list in `scopes.tf` specifically to enforce this (see that file's comments).

To add a scope: add an entry to `config/scopes.yaml` and run `terraform apply`. To remove one: remove the entry — Terraform will destroy the scope and its client assignments.

---

## Onboarding a hospital

1. Create `config/clients/{client_id}.yaml` with `client_id`, `client_name`, `organization_reference`, `fhir_url`, `jwks_url`, and `auth_level: "L2"`.
2. Run `terraform apply`.

---

## Revoking access

To decommission a hospital entirely: delete its L2 file from `config/clients/` and run `terraform apply`. There is no allow-list to clean up elsewhere.

## Temporarily disabling a client

To block a client from obtaining tokens without deleting its file or regenerating its `client_id`/`client_secret`: set `enabled: false` in its `config/clients/*.yaml` file and run `terraform apply`. Re-enable by removing the line (or setting it back to `true`) and applying again. Works the same for L1 and L2. This is the config-driven alternative to disabling via `kcadm`/the admin console, which this repo's clients are never meant to be hand-edited through.
