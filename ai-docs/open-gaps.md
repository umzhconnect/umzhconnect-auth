---
recap: "Prioritized action list — security issues and pending UMZH confirmations."
keywords: [.env git, .gitignore, .env.example, FhirContextMapper WARN, FhirContextMapper.java:98, tenant claim, ssl_required, start-dev, onboarding runbook, placer/fulfiller distinction, auth_level, ADR 0001]
---

# Open gaps and action list

From the 2026-06-16 meeting (Trifork pre-sync + call with USZ and Balgrist), updated through 2026-06-24.

## Priority order

1. **Fix `.env` in git** — `.env` contains `KEYCLOAK_ADMIN_PASSWORD=admin`, `PLACER_CLIENT_SECRET=placer-secret-2025`, etc. and is tracked by git. Add `.env` to `.gitignore`; create `.env.example` with placeholder values. Production will use Vault (see [ai-docs/terraform.md](terraform.md) §Secrets and Vault).

2. **Add WARN logging to `FhirContextMapper`** — `FhirContextMapper.java:98` silently swallows parse errors; a client sending malformed `authorization_details` gets a token with no `fhirContext` instead of any error. Log the parse exception at WARN level.

3. **Document onboarding runbook** — what a new hospital registration requires (`config/hospitals/` entry, who approves, how `terraform apply` is triggered). Document for non-engineers.

4. **Confirm `tenant` claim with UMZH** — `tenant-mapper` adds a `tenant` claim (`placer`/`fulfiller`) to every access token. It is a sandbox routing hint, not in the IG spec. Confirm with UMZH whether to retain or drop.

5. **Confirm scope of placer/fulfiller distinction** — the IG defines `placer` and `fulfiller` roles for the referral workflow specifically. It is not yet confirmed whether all UMZH Connect M2M use cases follow this model (e.g. lab result retrieval, imaging, medication lookups may not map cleanly). If the distinction applies only to the referral workflow, the `role` claim should be scoped accordingly. Resolve together with #4.

6. **Production hardening** — `ssl_required = "none"` in `realm.tf:11` (must be `external` or `all`); `start-dev` in `docker-compose.yml` disables all production hardening — document clearly as dev-only.

## Resolved

- `authorization_details` → `fhirContext` mapping: current implementation is correct. `FhirContextMapper` reads the raw request parameter and maps it into the AS-signed JWT. No design change needed.
- L1/L2/L3 direction: never L1 in production; no upgrade path between levels; L3 out of scope.
- Onboarding approach: Terraform, reproducible, VCS-based.
- One KC client per hospital: replaced D1-via-YAML (one client per org+app+FHIR server) with one client per hospital (`{org_id}`). See [aud-design.md](aud-design.md), [ADR 0002](../docs/adr/0002-one-client-per-hospital.md), [ADR 0003](../docs/adr/0003-defer-scope-and-audience-enforcement.md).
- L1 clients removed: `placer-client` / `fulfiller-client` are not in `clients.tf`. All provisioned clients are L2 (`private_key_jwt`).
- `users.tf` and `scopes.tf` removed: sandbox user accounts and user-facing consent scopes are not part of this config.
- `auth_level` claim: deferred until L3 is introduced. See [ADR 0001](../docs/adr/0001-defer-auth-level-claim.md).
- `validate-grants.py`: removed — the per-server grants model was superseded by ADR 0002.
- localhost `org_reference` defaults: removed — `org_reference` is sourced from each hospital's YAML file.

## External / pending

- IP/open-source agreement was pending legal review as of 2026-06-16.
- UMZH GitHub invites not yet done as of 2026-06-16.
- `umzhconnect/umzhconnect-auth` delivery target is still an empty stub.
