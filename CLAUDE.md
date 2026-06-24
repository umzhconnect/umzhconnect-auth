# CLAUDE.md — Instructions for Claude Code

## Project purpose

Keycloak-based OAuth 2.0 Authorization Server for the UMZH Connect ecosystem, implementing the IG's machine-to-machine security model. Three deliverables:

| Folder | What | Production? |
|--------|------|-------------|
| `keycloak/` | Custom Keycloak image + Terraform realm config | Yes |
| `token-validator/` | Mock resource server that validates tokens | No — dev/test only |
| `bruno/` | Request collection (auth, validation, negative cases) | No |

Key contacts: **David Altorfer** (Trifork project lead), **Andreas Ahlm** and **Michael** (USZ/UMZH side).

---

## Reference docs (ai-docs/)

Read the relevant doc before making changes. The frontmatter `keywords` field is the lookup index.

| Doc | What it covers |
|-----|----------------|
| [ai-docs/domain.md](ai-docs/domain.md) | FHIR, SMART on FHIR, referral flow |
| [ai-docs/realm-contract.md](ai-docs/realm-contract.md) | Realm settings, clients, mappers, sandbox parity |
| [ai-docs/config-model.md](ai-docs/config-model.md) | YAML config model — hospitals, onboarding |
| [ai-docs/terraform.md](ai-docs/terraform.md) | Terraform patterns and pitfalls |
| [ai-docs/mapper.md](ai-docs/mapper.md) | FhirContextMapper — raw session notes, not AuthorizationRequestContext |
| [ai-docs/infrastructure.md](ai-docs/infrastructure.md) | docker-compose, backchannel URL, jwks-server |
| [ai-docs/bruno.md](ai-docs/bruno.md) | Bruno collection, L2 sandbox mode |
| [ai-docs/token-validator.md](ai-docs/token-validator.md) | Token validator config and endpoints |
| [ai-docs/aud-design.md](ai-docs/aud-design.md) | Audience claim design — current state deferred, D3 migration path |
| [ai-docs/open-gaps.md](ai-docs/open-gaps.md) | Prioritized action list |

Architecture decisions: [`docs/adr/`](docs/adr/).

---

## Behavioral rules

### Before any auth decision — read the IG security docs

`~/github/umzhconnect/umzhconnect-ig/input/pagecontent/security.md` and `security-implementation.md` are the normative source. This repo's realm must remain a drop-in replacement for `umzhconnect-sandbox`. When in doubt, check the sandbox realm export.

### Production is L2 only — never propose L1 as production config

`client_secret` is banned from production. All production clients authenticate with `private_key_jwt`. Never include L1 in production proposals, never suggest it as a migration path or fallback.

### Terraform `extra_config` — no `attributes.` prefix

`extra_config` maps directly into Keycloak's `attributes` object. Adding `attributes.` yourself creates `attributes.attributes.foo` — silently ignored. Always use bare key names (`"jwks.url"`, not `"attributes.jwks.url"`).

### Never touch KC clients manually — everything is Terraform-managed

All KC clients are generated from `config/hospitals/*.yaml` files. Never hand-edit the KC admin console. If a client needs to change, change the YAML and run `terraform apply`.

### No implicit access — hospitals must be explicitly onboarded

A hospital with no `config/hospitals/{org_id}.yaml` file has no KC client and cannot obtain tokens. Adding a hospital is a deliberate provisioning step. See [ADR 0002](docs/adr/0002-one-client-per-hospital.md).

### Realm changes must stay sandbox-compatible

Unless the divergence is intentional and documented in [ai-docs/realm-contract.md](ai-docs/realm-contract.md), any realm change must keep the realm a valid drop-in for `umzhconnect-sandbox`. Acceptance test: the sandbox's Hurl suites in `tests/` should still pass.

---

## Keep ai-docs/ up to date

Update the relevant doc whenever you change the corresponding code.

| When you change… | Update… |
|------------------|---------|
| `keycloak/terraform/*.tf` | [ai-docs/terraform.md](ai-docs/terraform.md) and [ai-docs/realm-contract.md](ai-docs/realm-contract.md) |
| `keycloak/config/**` | [ai-docs/config-model.md](ai-docs/config-model.md) |
| `keycloak/mapper/src/**` | [ai-docs/mapper.md](ai-docs/mapper.md) |
| `docker-compose.yml` | [ai-docs/infrastructure.md](ai-docs/infrastructure.md) |
| `token-validator/src/**` | [ai-docs/token-validator.md](ai-docs/token-validator.md) |
| `bruno/**` | [ai-docs/bruno.md](ai-docs/bruno.md) |
| Audience / `aud` design decisions | [ai-docs/aud-design.md](ai-docs/aud-design.md) and add an ADR under `docs/adr/` |
| Any item in the open gaps list | [ai-docs/open-gaps.md](ai-docs/open-gaps.md) — mark resolved and move to "Resolved" |

Keep `keywords` in each doc's frontmatter in sync with the actual symbols and file paths after a change — stale keywords defeat the lookup purpose.

When making a significant architectural decision (non-obvious choice, explicit deferral, reversal), add an ADR in `docs/adr/` following the format in [`docs/adr/README.md`](docs/adr/README.md).
