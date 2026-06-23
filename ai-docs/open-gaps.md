---
recap: "Prioritized action list — security issues, sandbox artifacts to remove, and pending UMZH confirmations."
keywords: [.env git, .gitignore, .env.example, L1 gate, users.tf, smart scopes, direct_access_grants_enabled, FhirContextMapper WARN, FhirContextMapper.java:98, tenant claim, ssl_required, start-dev, onboarding runbook, placer/fulfiller distinction, auth_level, ADR 0001, validate-grants.py, two-PR workflow]
---

# Open gaps and action list

From the 2026-06-16 meeting (Trifork pre-sync + call with USZ and Balgrist), updated through 2026-06-19.

## Priority order

1. **Fix `.env` in git** — `.env` contains `KEYCLOAK_ADMIN_PASSWORD=admin`, `PLACER_CLIENT_SECRET=placer-secret-2025`, etc. and is tracked by git. Add `.env` to `.gitignore`; create `.env.example` with placeholder values. Production will use Vault (see `audience_architecture.md` §Secrets and Vault).

2. **Gate L1 clients** — `placer-client` / `fulfiller-client` in `clients.tf` are sandbox/PoC only. Add `enable_sandbox_clients = false` Terraform variable or remove from production config.

3. **Remove `users.tf` and `smart-*` scopes** — `keycloak/terraform/users.tf` is sandbox parity: `web-app` PKCE client with ROPC (`direct_access_grants_enabled = true`) and three demo users with hardcoded passwords. The `smart-*` scopes in `scopes.tf` are user-facing consent screen scopes, not M2M. Remove or gate behind a flag.

4. **Add WARN logging to `FhirContextMapper`** — `FhirContextMapper.java:98` silently swallows parse errors; a client sending malformed `authorization_details` gets a token with no `fhirContext` instead of any error. Log the parse exception at WARN level.

5. **Document onboarding runbook** — what a new app registration requires (`config/apps/` entry + grant entries from target orgs), who approves, how `terraform apply` is triggered. The two-PR workflow (app file PR + grants PRs) is the extension point; document it for non-engineers.

6. **Confirm `tenant` claim with UMZH** — `tenant-mapper` adds a `tenant` claim (`placer`/`fulfiller`) to every access token. It is a sandbox routing hint, not in the IG spec. Confirm with UMZH whether to retain or drop.

7. **Confirm scope of placer/fulfiller distinction** — the IG defines `placer` and `fulfiller` roles for the referral workflow specifically. It is not yet confirmed whether all UMZH Connect M2M use cases follow this model (e.g. lab result retrieval, imaging, medication lookups may not map cleanly). If the distinction applies only to the referral workflow, the `role` claim should be scoped accordingly. Resolve together with #6.

8. **Production hardening** — `ssl_required = "none"` in `realm.tf:11` (must be `external` or `all`); `start-dev` in `docker-compose.yml` disables all production hardening — document clearly as dev-only.

## Resolved

- `authorization_details` → `fhirContext` mapping: current implementation is correct. `FhirContextMapper` reads the raw request parameter and maps it into the AS-signed JWT. No design change needed.
- L1/L2/L3 direction: never L1 in production; no upgrade path between levels; L3 out of scope.
- Onboarding approach: Terraform, reproducible, VCS-based.
- Audience model: D1 implemented — one KC client per (app, target FHIR server), YAML-driven config. See [aud-design.md](aud-design.md) and [ADR 0002](../docs/adr/0002-audience-claim-design.md).
- `aud` claim: implemented via `aud:<server_key>` default scope on each KC client; `EXPECTED_AUDIENCE` enabled in token validator.
- `auth_level` claim: deferred until L3 is introduced. See [ADR 0001](../docs/adr/0001-defer-auth-level-claim.md).
- No default grants: all access must be explicit; `validate-grants.py` enforces this. See [ADR 0003](../docs/adr/0003-no-default-grant-scopes.md).
- localhost `org_reference` defaults: removed — `org_reference` is now sourced from each app's YAML file.

## External / pending

- IP/open-source agreement was pending legal review as of 2026-06-16.
- UMZH GitHub invites not yet done as of 2026-06-16.
- `umzhconnect/umzhconnect-auth` delivery target is still an empty stub.
