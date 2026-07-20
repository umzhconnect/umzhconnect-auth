# Operational use cases

Use cases relevant to platform operators managing the authentication service.
This is the runbook for processing customer (hospital) requests: onboarding,
configuration changes, lifecycle management, and incident response.

Everything in this document follows two invariants:

1. **All Keycloak state is Terraform-managed from VCS.** Every KC client is
   generated from `keycloak/config/hospitals/*.yaml`; every realm scope from
   `keycloak/config/scopes.yaml`. Never hand-edit the KC admin console — any
   change made there is silently reverted on the next `terraform apply` and is
   lost in disaster recovery ([UC-L5](#uc-l5--disaster-recovery)).
2. **One primary (L2) KC client per hospital, provisioned explicitly.** A
   hospital with no `config/hospitals/{org_id}.yaml` file has no KC client and
   cannot obtain tokens ([ADR 0002](../adr/0002-one-client-per-hospital.md)).
   The primary, production integration path is always `private_key_jwt` (L2).
   `client_secret` (L1) is **not** a production path — it exists only as an
   explicit, per-hospital, opt-in **debug client**
   (`config/hospitals-l1/{org_id}.yaml`, [ADR
   0004](../adr/0004-reinstate-l1-debug-client.md)) for connectivity
   troubleshooting, alongside — never instead of — the L2 client. Every
   token carries a required `extensions.umzhconnect.auth_level` claim
   (`"L1"`/`"L2"`) so resource servers can identify and reject L1 tokens for
   real clinical data flows ([UC-R6](technical.md#uc-r6--rs-enforces-a-minimum-auth_level)).

Architecture references: [ADR 0002 — one client per
hospital](../adr/0002-one-client-per-hospital.md), [ADR 0003 — constant
ecosystem `aud`](../adr/0003-constant-ecosystem-audience.md), [ADR 0004 —
reinstate L1 as a debug client](../adr/0004-reinstate-l1-debug-client.md),
[ai-docs/config-model.md](../../ai-docs/config-model.md).

---

## Requests you must decline (or escalate)

Customer requests that the current architecture deliberately does not support.
Do not improvise these in the KC admin console — each has an ADR explaining the
deferral and its revisit condition.

| Request | Why it can't be done | Reference |
|---------|---------------------|-----------|
| "Give our app a `client_secret`" for production use | `client_secret` (L1) is banned as a production/primary/fallback client; the production path is always L2 `private_key_jwt`. If the ask is really about debugging connectivity, see [UC-O5](#uc-o5--provisioning-an-l1-debug-client) instead | [CLAUDE.md](../../CLAUDE.md), [ADR 0004](../adr/0004-reinstate-l1-debug-client.md), IG security model |
| "We want a separate client per application" | One client per hospital; all apps of a hospital share one identity. Revisit when the Policy Server arrives | [ADR 0002](../adr/0002-one-client-per-hospital.md) |
| "Tokens for our FHIR server should only work for us" (per-target `aud`) | `aud` is a constant ecosystem value; target-specific audience binding is deferred until Keycloak supports RFC 8707 non-experimentally | [ADR 0003](../adr/0003-constant-ecosystem-audience.md) |
| "Only hospitals X and Y should get tokens for our server" (inbound allow-list) | There is no per-hospital allow-list of any kind; FHIR servers are responsible for their own authorization | [ADR 0003](../adr/0003-constant-ecosystem-audience.md) |
| "Grant scope S only to hospital X" | Scopes are realm-wide: `default_scopes` are assigned to every M2M client, `optional_scopes` are requestable by every client. Per-(caller, target) scope enforcement is a Policy Server concern | [ADR 0002](../adr/0002-one-client-per-hospital.md), [config-model.md](../../ai-docs/config-model.md) |
| "We want mTLS / DPoP (L3)" | L3 is out of scope until specified by the IG; the `auth_level` claim is deferred with it | [ADR 0001](../adr/0001-defer-auth-level-claim.md) |

---

## UC-O — Onboarding and provisioning

### UC-O0 — Initial setup

The authentication server is stood up for the first time in an environment.
All subsequent operations assume this has been completed.

**Actor:** platform operator
**Trigger:** new environment provisioned

**Kubernetes (ArgoCD) — the deployment path:**
1. Build and publish the four images this repo produces: `keycloak` (custom
   image with the `FhirContextMapper` JAR bundled in), `token-validator`,
   `tf-config` (bakes in `keycloak/terraform` + `keycloak/config`), and
   `jwks-server`.
2. Stand up Keycloak, its Postgres database, and a configurator `Job` that
   runs `terraform apply` against the running instance as an ArgoCD
   `PostSync` hook, using the config baked into the `tf-config` image.
   [`argocd-template/`](../../argocd-template) in this repo is a trimmed,
   generalized sample of these manifests (Deployment, Service, PostSync Job,
   kustomization) — see [argocd-template/README.md](../../argocd-template/README.md)
   for what's included and how to adapt it (namespace, hostnames,
   secrets-store, image registry). The concrete dev deployment built from
   this pattern lives in the separate `tch-umzh-connect-gitops` repo; see
   [ai-docs/umzh-connect-gitops.md](../../ai-docs/umzh-connect-gitops.md).
3. The configurator Job creates the realm, scopes, mappers, and one KC client
   per file in `config/hospitals/`. Terraform state must persist across Job
   re-runs (e.g. a PVC, as in the sample's `keycloak-config-job.yaml`) —
   otherwise every sync re-creates the realm from scratch.
4. Verify: run the Bruno collection (`bru run --env <your-env> --sandbox
   unsafe` inside `bruno/`) or acquire a token manually and POST it to the
   token-validator's `/validate`.

**Postcondition:** realm `umzh-connect` is live; all configured hospitals can
authenticate.

**Production note:** `start-dev` disables all Keycloak hardening and is
dev-only — production uses `start --optimized`, `ssl_required = "external"`
in `realm.tf`, and secrets from a vault, not plaintext Secrets.

**Local (docker-compose), for development:** the same steps run against a
local stack instead of a cluster — see
[ai-docs/infrastructure.md](../../ai-docs/infrastructure.md).
```sh
docker compose up -d --build        # builds & starts Keycloak, jwks-server, token-validator
docker compose up keycloak-config   # applies Terraform (or run it on the host, see below)
```
Admin console at `http://localhost:8180`. To run Terraform directly on the
host instead of via the compose service:
```sh
TF_VAR_keycloak_url=http://localhost:8180 terraform -chdir=keycloak/terraform apply
```

---

### UC-O1 — Onboarding a new hospital

A hospital joins the UMZH Connect network. This is the single provisioning
step: it creates the hospital's M2M identity and, with it, the ability to
obtain tokens accepted anywhere in the ecosystem.

**Actor:** platform operator, on request of the joining hospital
**Trigger:** hospital signs up to the network

**Information to collect from the hospital:**

| Field | What to ask for |
|-------|-----------------|
| `org_id` | Stable short identifier — becomes the KC `client_id` and the filename. Choose carefully: renaming later is an offboard + re-onboard ([UC-O3](#uc-o3--changing-a-hospitals-metadata-or-jwks-url)) |
| `org_display_name` | Human-readable name (shown in KC admin) |
| `org_reference` | Canonical FHIR `Organization` reference URL — embedded by the AS in every token as `extensions.umzhconnect.organization_reference`; resource servers use it for consent lookup |
| `fhir_url` | Base URL of the hospital's own FHIR server (recorded for reference; not written into `aud` — see [ADR 0003](../adr/0003-constant-ecosystem-audience.md)) |
| `jwks_url` | Public HTTPS endpoint where the hospital publishes the JWKS for its L2 signing key. Must be reachable from Keycloak |

**Steps:**
1. Create `keycloak/config/hospitals/{org_id}.yaml` with the five fields above
   (filename stem must equal `org_id`).
2. PR review and merge.
3. `terraform apply` (see [UC-O4](#uc-o4--rolling-out-a-config-change-per-environment)
   for how this happens per environment). Terraform creates KC client
   `{org_id}` with service account, `private_key_jwt` auth against the
   registered `jwks_url`, all `default_scopes`, and the four protocol mappers
   (`client_id`, org reference, FHIR context, ecosystem audience).
4. Verify: the hospital acquires a token with `client_id={org_id}` and a
   signed client assertion; check the token carries the expected
   `organization_reference` and scopes (see
   [technical.md UC-T1](technical.md#uc-t1--hospital-acquires-a-token-l2)).

**Postcondition:** hospital can authenticate and obtain tokens. Note the
consequence of [ADR 0003](../adr/0003-constant-ecosystem-audience.md): those
tokens carry the constant ecosystem `aud` and are structurally acceptable at
*every* FHIR server in the network — onboarding is network-wide, not
per-target. Data-level authorization is each FHIR server's (and later the
Policy Server's) responsibility.

---

### UC-O2 — Adding or removing a realm scope

A new resource type joins the data-sharing model (new SMART scope), or a scope
is retired.

**Actor:** platform operator
**Trigger:** IG / data-sharing model change

**Steps:**
1. Edit `keycloak/config/scopes.yaml`:
   - `default_scopes` — assigned to every hospital client, always present in
     issued tokens.
   - `optional_scopes` — registered in the realm; any client may request them
     explicitly via the `scope` parameter, but they are not included by
     default.
2. PR review and merge.
3. `terraform apply` — new scopes are created and assigned; removed entries
   are destroyed together with their client assignments.

**Postcondition:** subsequently issued tokens reflect the change. Tokens
issued before the apply keep the old scope set until expiry (max 300 s).

**Caution:** scope changes are realm-wide — a new `default_scope` lands in
*every* hospital's tokens. There is no per-hospital scope assignment
(see "Requests you must decline" above).

---

### UC-O3 — Changing a hospital's metadata or JWKS URL

A hospital changes a property of its registration — most commonly the
`jwks_url` (key endpoint moved), or `org_reference` / display name.

**Actor:** platform operator, on request of the hospital
**Trigger:** infrastructure change, org metadata update

**Steps:**
1. Edit `keycloak/config/hospitals/{org_id}.yaml`.
2. PR review and merge.
3. `terraform apply` — the KC client is updated in place.

**Postcondition:** Keycloak uses the new metadata immediately. If `jwks_url`
changed, Keycloak fetches the JWKS from the new URL on the next token request.

**Note:** changing `org_id` is a rename, not an in-place update — the KC
`client_id` encodes it. Treat it as offboarding the old identity
([UC-L2](#uc-l2--offboarding-a-hospital)) plus onboarding a new one
([UC-O1](#uc-o1--onboarding-a-new-hospital)), coordinated with the hospital so
its systems switch `client_id` at the cutover.

---

### UC-O4 — Rolling out a config change per environment

How a merged config change (hospital YAML, scopes YAML, or `.tf` change)
actually reaches a running Keycloak.

**Actor:** platform operator / CI
**Trigger:** any merge touching `keycloak/config/**` or `keycloak/terraform/**`

| Environment | Mechanism |
|-------------|-----------|
| Kubernetes (ArgoCD) | Publish a new `tf-config` image (bakes in `keycloak/terraform` + `keycloak/config`); an image-updater bumps the tag in the gitops manifests, and the ArgoCD `PostSync` Job re-runs `terraform apply` with state persisted on a PVC. See [argocd-template/](../../argocd-template) for the manifest shape and [ai-docs/umzh-connect-gitops.md](../../ai-docs/umzh-connect-gitops.md) for the concrete dev-cluster instance of this pattern (CI workflow names, image-updater config, PVC name) |
| Local (docker-compose), for development | `docker compose up keycloak-config`, or `terraform -chdir=keycloak/terraform apply` with `TF_VAR_keycloak_url=http://localhost:8180` |
| Production | Not yet stood up — the delivery target is a config snapshot for `umzhconnect/umzhconnect-auth` (pending) |

**Postcondition:** the realm in that environment matches VCS.

---

### UC-O5 — Provisioning an L1 debug client

A hospital asks for a `client_secret` to unblock connectivity debugging
(firewall, proxy, JWKS reachability) that's hard to isolate through L2's
signed-assertion flow — see [ADR 0004](../adr/0004-reinstate-l1-debug-client.md).

**This is a debug/test aid, not a production integration path.** L1 must
never be proposed as an alternative to onboarding via L2
([UC-O1](#uc-o1--onboarding-a-new-hospital)); it exists alongside the L2
client, not instead of it, and is scoped to troubleshooting — not real
clinical data flows.

**Actor:** platform operator, on request of the hospital
**Trigger:** hospital reports L2 connectivity/firewall/JWKS issues it needs
to isolate

**Steps:**
1. Confirm the request is genuinely about connectivity debugging, not a way
   to avoid implementing `private_key_jwt`. If the hospital wants a
   long-term `client_secret` integration, decline per the "Requests you must
   decline" table above.
2. Create `keycloak/config/hospitals-l1/{org_id}.yaml` with
   `org_display_name`, `org_reference`, and (recommended for traceability)
   `reason` / `requested_by` / `requested_date` — see [the directory's
   README](../../keycloak/config/hospitals-l1/README.md) for the field
   schema. Independent of the L2 file for the same `org_id`: the hospital
   may have an L1 file, an L2 file, both, or neither, in any order.
3. PR review and merge.
4. `terraform apply` — creates KC client `{org_id}--l1` with a
   Keycloak-generated `client_secret`, `client_credentials` grant, the same
   default/optional scopes and mapper set as the L2 client (org reference,
   FHIR context, ecosystem audience), plus `extensions.umzhconnect.auth_level`
   hardcoded to `"L1"`.
5. Hand the generated `client_secret` to the hospital (see [ADR
   0004](../adr/0004-reinstate-l1-debug-client.md) for the relaxed-but-scoped
   secret-handling exception this client gets — it's still not to be reused
   as a general credential-handling precedent).
6. Verify: the hospital acquires a token per [technical.md
   UC-T8](technical.md#uc-t8--debug-client-acquires-an-l1-token) and confirms
   `extensions.umzhconnect.auth_level = "L1"`.

**Postcondition:** hospital can obtain L1 debug tokens alongside (or instead
of, if it hasn't onboarded L2 yet) its L2 client. Revoking L1 access mirrors
offboarding: delete `config/hospitals-l1/{org_id}.yaml` and `terraform
apply` — this is independent of, and does not affect, the hospital's L2
client.

---

## UC-L — Lifecycle, revocation, and incidents

### UC-L1 — Hospital rotates its L2 signing key

A hospital generates a new RSA key pair and updates its published JWKS. No
operator action is required as long as the `jwks_url` itself is unchanged.

**Actor:** hospital
**Trigger:** key rotation policy or precaution

**Steps (hospital side):**
1. Generate the new key pair; publish the new public key with a **new `kid`**
   at the existing `jwks_url`, keeping the old key in the set temporarily.
2. Start signing client assertions with the new key/`kid`. Keycloak re-fetches
   the JWKS when it sees an unknown `kid` and verifies against the new key.
3. Remove the old key from the JWKS once no in-flight assertions remain.

**Postcondition:** tokens issued under the new key; zero operator involvement.
Only if the `jwks_url` itself moves does the operator act
([UC-O3](#uc-o3--changing-a-hospitals-metadata-or-jwks-url)).

**Operator guidance when a hospital reports "signature verification suddenly
fails after our rotation":** the usual cause is reusing the old `kid` for the
new key (Keycloak serves the cached key for a known `kid`) or removing the old
key before in-flight assertions drained. Verify the JWKS endpoint serves both
keys with distinct `kid`s during the overlap window.

---

### UC-L2 — Offboarding a hospital

A hospital leaves the network or is decommissioned.

**Actor:** platform operator
**Trigger:** contract end, decommissioning

**Steps:**
1. Delete `keycloak/config/hospitals/{org_id}.yaml`. There is no allow-list
   or grants file to clean up elsewhere.
2. PR review and merge.
3. `terraform apply` — the KC client and its mappers are destroyed.

**Postcondition:** the hospital can no longer obtain tokens. Tokens already
issued remain valid until expiry (max 300 s); for anything faster see
[UC-L3](#uc-l3--compromise-response-immediately-block-a-hospital).

---

### UC-L3 — Compromise response: immediately block a hospital

A hospital's signing key is suspected compromised and its access must stop
faster than the normal PR + apply cycle.

**Actor:** platform operator
**Trigger:** security incident

**Options, fastest first:**
- **Disable the KC client** — set `enabled = false` on the client. For speed
  this may be done in the KC admin console *as a documented emergency
  exception* to the no-manual-changes rule — but it must be immediately
  followed by the same change in Terraform (add `enabled = false` handling or
  remove the hospital YAML and apply), otherwise the next `terraform apply`
  silently re-enables the client.
- **Offboard via config** — [UC-L2](#uc-l2--offboarding-a-hospital) with an
  expedited merge.

In both cases: new token requests are rejected immediately; tokens already
issued remain valid up to 300 s. Because `aud` is the constant ecosystem value
([ADR 0003](../adr/0003-constant-ecosystem-audience.md)), a leaked *token* is
usable at any FHIR server for its remaining lifetime — notify the affected
FHIR server operators so they can apply their own blocks if warranted.

**Postcondition (best effort):** no new tokens; existing tokens expire within
300 s.

---

### UC-L4 — Updating the authentication server

The Keycloak image is updated (new Keycloak version, `FhirContextMapper`
change, or base-image CVE patch).

**Actor:** platform operator
**Trigger:** new Keycloak release, mapper fix, CVE

**Steps:**
1. Update the version pin in `keycloak/Dockerfile`.
2. Review Keycloak release notes for breaking changes to the protocol-mapper
   SPI, token format, or Terraform provider compatibility. In particular,
   check whether `resource-indicators` (RFC 8707) has left experimental status
   — [ADR 0003](../adr/0003-constant-ecosystem-audience.md) requires
   re-evaluating the `aud` design on every KC version bump.
3. Rebuild and test: `docker compose build keycloak` locally, then run the
   Bruno collection and token-validator checks against the new image.
4. Publish the image; the Kubernetes deployment's image-updater (see
   [ai-docs/umzh-connect-gitops.md](../../ai-docs/umzh-connect-gitops.md) for
   the dev-cluster instance — `ci-keycloak.yml` / `argocd-image-updater`)
   picks up the new tag and rolls it out.
5. If the Terraform provider version also changed, run `terraform apply` after
   the new instance is healthy.

**Postcondition:** new image running; realm config unchanged unless an apply
was needed.

---

### UC-L5 — Disaster recovery

The Keycloak database or the Terraform state is lost.

**Actor:** platform operator
**Trigger:** database corruption, accidental deletion, infrastructure failure

**Full DB loss — realm reconstruction:**
1. Provision a fresh Keycloak instance ([UC-O0](#uc-o0--initial-setup)).
2. `terraform apply` against it with fresh state. Every realm object — realm,
   scopes, clients, mappers — is declared in Terraform from the YAML config,
   so the realm is fully rebuilt from VCS. No admin-console work.

**Terraform state loss only (DB intact):** re-attach state with
`terraform import` per resource. Do **not** apply against an empty state with
a live realm — Terraform would try to recreate everything and Keycloak rejects
the duplicates.

In a Kubernetes deployment the state typically lives on the configurator
Job's PVC (see [argocd-template/](../../argocd-template)`keycloak-config-job.yaml`);
losing that PVC is the state-loss case above.

**Postcondition:** realm restored to the state described in VCS.

**Dependency:** recovery relies entirely on VCS being the source of truth —
which is why manual KC admin changes are banned. Anything changed out-of-band
is permanently lost.
