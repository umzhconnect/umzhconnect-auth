# Operational use cases

Use cases relevant to platform operators and organization administrators managing
the authentication service in production. Covers onboarding, provisioning, and
lifecycle management.

---

## UC-O — Onboarding and provisioning

### UC-O0 — Initial setup

The authentication server is stood up for the first time in an environment
(local, staging, or production). All subsequent operations assume this has been
completed.

**Actor:** platform operator  
**Trigger:** new environment provisioned  
**Steps:**
1. Build and start the Keycloak container:
   ```sh
   docker compose up -d --build
   ```
   This builds the custom image with the `FhirContextMapper` JAR bundled in.
2. Wait for Keycloak to be healthy (admin console reachable at
   `http://localhost:8180`).
3. Apply the Terraform realm configuration:
   ```sh
   docker compose up keycloak-config
   ```
   Or directly:
   ```sh
   TF_VAR_keycloak_url=http://localhost:8180 \
     terraform -chdir=keycloak/terraform apply -auto-approve
   ```
   This creates the realm, scopes, roles, audience mappers, and all KC clients
   derived from the current `config/apps/` and `config/grants/` YAML files.
4. Verify: acquire a token and run it through the token validator
   (`POST /validate`).

**Postcondition:** realm `umzh-connect` is live; all configured clients can
authenticate.

**Note:** for production, replace `start-dev` with `start --optimized`, set
`ssl_required = "external"` in `realm.tf`, and source the Keycloak admin
password from Vault rather than the `.env` file.

---

### UC-O1 — New organization registers

A new hospital or organization joins the UMZH Connect network by submitting its
first application file. Registration alone confers no access — the org's apps
remain inert until a target org actively grants them access via a grants file.

**Actor:** calling org (new)  
**Trigger:** org wants to participate in the network  
**Steps:**
1. Org creates `config/apps/{org_id}--{app_id}.yaml` with its JWKS URL, org
   metadata, and declared scopes.
2. PR reviewed and merged.
3. No KC client is created; no `terraform apply` is required at this point.

**Postcondition:** org is registered but has no access to any FHIR server.

---

### UC-O2 — Existing org registers a new application

An already-registered organization adds a new application (e.g. a second system
integrating with the network).

**Actor:** calling org (existing)  
**Trigger:** org deploys a new app that needs API access  
**Steps:**
1. Org creates `config/apps/{org_id}--{new_app_id}.yaml`.
2. PR reviewed and merged.
3. Inert until one or more target orgs grant it access.

**Postcondition:** new app registered; still no KC client until granted.

---

### UC-O3 — Target org grants a calling app access to its FHIR server

The org operating a FHIR server decides to allow a specific calling app to
access it, with an explicit scope set.

**Actor:** target org (FHIR server operator)  
**Trigger:** bilateral agreement to share data  
**Steps:**
1. Target org adds an entry to `config/grants/{server_key}.yaml` for the calling
   app's `{org_id}--{app_id}` key, listing the permitted SMART scopes.
2. Run `scripts/validate-grants.py` to confirm all declared required scopes are
   covered.
3. PR reviewed and merged.
4. `terraform apply` — Keycloak client `{org_id}--{app_id}--{server_key}` is
   created with the granted scopes and the `aud:{server_key}` audience scope as
   default.

**Postcondition:** calling app can acquire tokens scoped to that FHIR server.

---

### UC-O4 — New FHIR server added to the network

An organization deploys a new FHIR server and wants to make it reachable via the
network's token infrastructure.

**Actor:** platform operator / target org  
**Trigger:** new FHIR server goes live  
**Steps:**
1. Add entry to `config/fhir-servers.yaml` (`server_key` → URL + description).
2. Create `config/grants/{server_key}.yaml` (initially empty or with first
   grants).
3. `terraform apply` — creates the `aud:{server_key}` scope and audience mapper
   in Keycloak.

**Postcondition:** new server is reachable; any app granted access gets the
correct `aud` claim pointing to its URL.

---

### UC-O5 — Grant validation before apply

Before running `terraform apply` after any config change, the grant graph is
validated to catch consistency errors early.

**Actor:** platform operator / CI pipeline  
**Trigger:** any change to `config/apps/` or `config/grants/`  
**Steps:**
1. Run `scripts/validate-grants.py`.
2. Script checks: every app key referenced in a grants file has a matching app
   config; every `required_scope` declared by an app is covered by each grant
   targeting it.
3. On failure, the error is reported and `terraform apply` is blocked.

**Postcondition:** grant graph is consistent; apply is safe to run.

---

### UC-O6 — Updating granted scopes for an existing app

A target org changes the scope set it grants to an already-provisioned calling
app — either expanding or restricting the permissions on an existing bilateral
access relationship.

**Actor:** target org (FHIR server operator)  
**Trigger:** policy change, new resource type added to the data-sharing agreement  
**Steps:**
1. Edit the relevant entry in `config/grants/{server_key}.yaml`, adding or
   removing SMART scopes for the app.
2. Run `scripts/validate-grants.py` to confirm all required scopes declared by
   the app are still covered (relevant when restricting).
3. PR reviewed and merged.
4. `terraform apply` — Keycloak client
   `{org_id}--{app_id}--{server_key}` is updated; its default scope set
   reflects the new grant.

**Postcondition:** subsequently issued tokens carry the updated scope set.
Tokens issued before the apply remain valid with the old scopes until expiry
(max 300 s).

---

### UC-O7 — Updating application metadata or JWKS URL

A calling org changes a property of its registered application — for example the
`jwks_url` (hosting the signing key at a new endpoint), `org_reference`, or
display name.

**Actor:** calling org  
**Trigger:** infrastructure change, org metadata update  
**Steps:**
1. Edit `config/apps/{org_id}--{app_id}.yaml` with the new value.
2. PR reviewed and merged.
3. `terraform apply` — Keycloak client(s) for that app are updated in place.

**Postcondition:** Keycloak uses the new metadata immediately. If `jwks_url`
changed, Keycloak will fetch the JWKS from the new URL on the next token
request.

**Note:** changing `org_id` or `app_id` is a rename and is not an in-place
update — it requires offboarding the old app (UC-L3) and onboarding a new one
(UC-O1/O2/O3), because the KC client ID encodes both values.

---

## UC-L — Lifecycle and revocation

### UC-L1 — Organization rotates its L2 signing key

A calling org generates a new RSA key pair and updates its public JWKS endpoint.
No Keycloak reconfiguration is required as long as the `jwks_url` in the app
config has not changed.

**Actor:** calling org  
**Trigger:** key rotation policy or suspected key compromise  
**Steps:**
1. Org generates new key pair; publishes new key (with a new `kid`) at the
   existing `jwks_url` endpoint (the old key may be retained temporarily for
   in-flight assertions).
2. Keycloak re-fetches the JWKS on the next token request that references the
   new `kid`.
3. Old key is removed from the JWKS endpoint once no in-flight assertions remain.

**Postcondition:** tokens are issued using the new key; no operator action
required unless `jwks_url` itself changes (which would require a config PR +
`terraform apply`).

**Open question:** what is Keycloak's JWKS cache TTL, and is there a forced
re-fetch mechanism if the cache causes a gap?

---

### UC-L2 — Access revoked for one app to one FHIR server

A bilateral access relationship is terminated — the calling app loses access to a
specific FHIR server while retaining access to others.

**Actor:** target org (FHIR server operator) or platform operator  
**Trigger:** end of data-sharing agreement or policy decision  
**Steps:**
1. Remove the app's entry from `config/grants/{server_key}.yaml`.
2. PR reviewed and merged.
3. `terraform apply` — KC client `{org_id}--{app_id}--{server_key}` is destroyed.

**Postcondition:** app can no longer acquire tokens for that FHIR server.
Previously issued tokens remain valid until expiry (max 300 s). For immediate
invalidation, see UC-L5.

---

### UC-L3 — App fully offboarded

A calling app is decommissioned across the entire network.

**Actor:** platform operator  
**Trigger:** org leaves network or decommissions system  
**Steps:**
1. Remove all grant entries for `{org_id}--{app_id}` across all grants files.
2. Remove `config/apps/{org_id}--{app_id}.yaml`.
3. `terraform apply` — all KC clients for that app are destroyed.

**Postcondition:** app has no KC clients anywhere; cannot acquire any token.

---

### UC-L4 — FHIR server decommissioned

A FHIR server is taken offline and all associated access grants are removed.

**Actor:** platform operator / target org  
**Trigger:** server shutdown or org withdrawal  
**Steps:**
1. Remove all entries from `config/grants/{server_key}.yaml` (or delete the
   file).
2. Remove the server entry from `config/fhir-servers.yaml`.
3. `terraform apply` — all KC clients for that server are destroyed; the
   `aud:{server_key}` scope is removed.

**Postcondition:** no app can acquire a token targeting that server.

---

### UC-L5 — Compromise response: immediately block a client

A signing key or client is suspected compromised and access must be stopped
faster than token expiry.

**Actor:** platform operator  
**Trigger:** security incident  
**Options:**
- **Disable in Keycloak** — set `enabled = false` on the KC client via Terraform
  or admin console. New token requests are rejected immediately. Tokens already
  issued remain valid until expiry (max 300 s).
- **Destroy the KC client** — remove grant entry + `terraform apply`. New
  requests rejected; existing tokens still valid until expiry.
- **Token revocation** — Keycloak supports a revocation policy (`notBefore`
  timestamp) that can invalidate all tokens issued before a given point, provided
  resource servers check it via introspection or honour the `notBefore` claim.

**Open question:** is token introspection (or `notBefore` enforcement) required
at resource servers to support true immediate revocation? This needs to be
confirmed with UMZH and specified in the IG security model.

**Postcondition (best effort):** no new tokens issued; existing tokens expire
within 300 s.

---

### UC-L6 — Updating the authentication server

The Keycloak image is updated (new Keycloak version, updated `FhirContextMapper`,
or base image security patch).

**Actor:** platform operator  
**Trigger:** new Keycloak release, mapper bug fix, CVE in base image  
**Steps:**
1. Update the version pin in `keycloak/Dockerfile` (and `docker-compose.yml` if
   referenced separately).
2. Rebuild the image:
   ```sh
   docker compose build keycloak
   ```
3. Review Keycloak release notes for breaking changes to the mapper SPI, token
   format, or Terraform provider compatibility.
4. Run the full test suite (Bruno collection + token validator) against the new
   image in a non-production environment before promoting.
5. Deploy to production (rolling restart or blue/green depending on the
   environment).
6. If the Terraform provider version is also bumped, run `terraform apply` after
   the new KC instance is healthy to reconcile any provider-side changes.

**Postcondition:** new image running; existing realm config and KC clients
unchanged unless a `terraform apply` was required.

**Note:** `start-dev` (used in the local compose setup) disables all Keycloak
production hardening. Production deployments must use `start --optimized` with a
pre-built optimized image.

---

### UC-L7 — Disaster recovery

The Keycloak database or Terraform state is lost and the realm must be
reconstructed from the VCS-managed configuration.

**Actor:** platform operator  
**Trigger:** database corruption, accidental deletion, infrastructure failure  

**Realm reconstruction (full DB loss):**
1. Provision a fresh Keycloak instance (UC-O0 step 1).
2. Run `terraform apply` against the fresh instance. Because all realm objects
   are declared in Terraform from the YAML config, the full realm — clients,
   scopes, mappers, roles — is recreated from VCS.
3. No manual Keycloak admin console work is required.

**Terraform state loss only (DB intact):**
1. Run `terraform import` for each existing KC resource to re-attach the state
   file to the live objects.
2. Alternatively, if the realm is fully intact and consistent with VCS, delete
   and recreate the state by running `terraform apply` against an empty state
   (Terraform will see all resources as new and attempt to create them; KC will
   reject duplicates — use `terraform import` per resource to avoid this).

**Postcondition:** realm restored to the state described in VCS. Any KC clients
or config changes made outside Terraform (e.g. via admin console) are not
recoverable.

**Dependency:** recovery relies entirely on VCS being the source of truth. Any
out-of-band changes to the KC realm that were not committed are permanently lost.

---

### UC-L8 — L2 → L3 upgrade path

A calling app moves from `private_key_jwt` (L2) to a stronger client
authentication mechanism such as mTLS or DPoP (L3), once L3 support is
introduced into the platform.

**Actor:** calling org + platform operator  
**Trigger:** L3 support available in platform; org opts in  

**Design constraint:** there is no in-place upgrade between authentication
levels. The IG model provisions each client at the correct level from day one.
A client moving from L2 to L3 is treated as a new application registration.

**Steps:**
1. Platform operator confirms L3 support is available in the current Keycloak
   version and the Terraform provider (see ADR 0001 — revisit condition).
2. Calling org registers a new app entry (UC-O2) with L3 configuration (mTLS
   certificate DN or DPoP binding, as defined when L3 is specified).
3. Target orgs update their grants files to grant the new L3 app entry access
   (UC-O3). The old L2 app entry may run in parallel during transition.
4. Calling org migrates traffic to the new L3 client ID.
5. Once traffic is fully migrated, the L2 app is offboarded (UC-L3).

**Postcondition:** app operates at L3; L2 KC clients destroyed; no parallel
credentials remain.

**Note:** the `auth_level` claim (deferred in ADR 0001) will be introduced at
this point, allowing resource servers to enforce a minimum authentication level
policy.
