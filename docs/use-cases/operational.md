# Operational use cases

Use cases relevant to platform operators managing the authentication service.
This is the runbook for processing customer (hospital) requests: onboarding,
configuration changes, lifecycle management, and incident response.

Everything in this document follows two invariants:

1. **All Keycloak state is Terraform-managed from VCS.** Every KC client is
   generated from a `config/clients/*.yaml` file (its own `auth_level` field
   determines whether it's L1 or L2); every realm scope from a
   `scopes.yaml` config file (see "Where hospital/scope config actually
   lives" below for where those files live in your environment). Never
   hand-edit the KC admin console — any change made there is silently
   reverted on the next `terraform apply` and is lost in disaster recovery
   ([UC-L5](#uc-l5--disaster-recovery)).
2. **One primary (L2) KC client per hospital, provisioned explicitly.** A
   hospital with no `config/clients/*.yaml` file with `auth_level: "L2"` has
   no KC client and cannot obtain tokens ([ADR 0002](../adr/0002-one-client-per-hospital.md)).
   The primary, production integration path is always `private_key_jwt` (L2).
   `client_secret` (L1) is **not** a production path — it exists only as an
   explicit, per-hospital, opt-in **debug client**
   (a `config/clients/*.yaml` file with `auth_level: "L1"`, [ADR
   0004](../adr/0004-reinstate-l1-debug-client.md)) for connectivity
   troubleshooting, alongside — never instead of — the L2 client. Every
   token carries a required `extensions.umzhconnect.auth_level` claim
   (`"L1"`/`"L2"`) so resource servers can identify and reject L1 tokens for
   real clinical data flows ([UC-R6](technical.md#uc-r6--rs-enforces-a-minimum-auth_level)).

Architecture references: [ADR 0002 — one client per
hospital](../adr/0002-one-client-per-hospital.md), [ADR 0003 — constant
ecosystem `aud`](../adr/0003-constant-ecosystem-audience.md), [ADR 0004 —
reinstate L1 as a debug client](../adr/0004-reinstate-l1-debug-client.md).

---

## Where hospital/scope config actually lives

This repo ships the Terraform *logic* (`keycloak/terraform/*.tf`) and, as a
convenience, a `keycloak/config/` YAML tree so the local docker-compose stack
has something to apply out of the box — that copy is a demonstration fixture
only, not a production config source.

A real deployment keeps its own config outside this repo, in whatever repo
drives its deployment (e.g. a gitops repo), using the same YAML shape. The
generic sample under [`./argocd-template`](../../argocd-template) shows the
pattern: hospital/scope YAML lives under `keycloak_config/` in *your*
deployment repo and is mounted into the Terraform-apply Job via a kustomize
`configMapGenerator` — kept out of the Terraform image so onboarding a
hospital never requires rebuilding or republishing anything from this repo.
See [`argocd-template/README.md`](../../argocd-template/README.md) for the
exact file layout.

So throughout this document, "edit `keycloak/config/clients/*.yaml`"
means: edit that file in whichever location is authoritative for your
environment — this repo's copy for the local docker-compose demo, or the
equivalent file in your deployment repo's `keycloak_config/` directory
(modeled on `./argocd-template`) for a real deployment. Only the Terraform
`.tf` logic itself is versioned in this repo for every environment.

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
| "Grant scope S only to hospital X" | Scopes are realm-wide: every scope in `config/scopes.yaml` is requestable by every M2M client (none is assigned by default). Per-(caller, target) scope enforcement is a Policy Server concern | [ADR 0002](../adr/0002-one-client-per-hospital.md) |
| "We want mTLS / DPoP (L3)" | L3 is out of scope until specified by the IG; the `auth_level` claim is deferred with it | [ADR 0001](../adr/0001-defer-auth-level-claim.md) |

---

## UC-O — Onboarding and provisioning

### UC-O0 — Initial setup

The authentication server is set up for the first time in an environment.
All subsequent operations assume this has been completed.

**Actor:** platform operator
**Trigger:** new environment provisioned

**Kubernetes (ArgoCD or similar) — the deployment path:**
1. Build and publish the four images this repo produces: `keycloak` (custom
   image with the `FhirContextMapper` JAR bundled in), `token-validator`,
   `tf-config` (a Terraform image built from this repo's
   `keycloak/terraform/` logic only — no hospital/scope config), and
   `jwks-server`.
2. Set up Keycloak, its Postgres database, and a configurator `Job` that
   runs `terraform apply` against the running instance as a post-deploy hook
   (e.g. an ArgoCD `PostSync` hook), reading hospital/scope config from
   *your own* deployment repo (see "Where hospital/scope config actually
   lives" above) rather than from anything baked into the `tf-config` image.
   [`argocd-template/`](../../argocd-template) in this repo is a trimmed,
   generalized sample of these manifests (Deployment, Service, PostSync Job,
   kustomization) — see [argocd-template/README.md](../../argocd-template/README.md)
   for what's included and how to adapt it (namespace, hostnames,
   secrets-store, image registry).
3. The configurator Job creates the realm, scopes, mappers, and one KC client
   per hospital config file. Terraform state must persist across Job
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
local stack instead of a cluster.
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
| `client_id` | Stable identifier — the KC `client_id` directly, read from the file's own field, not the filename. Convention: `{hospital_name}-l2` (e.g. `hospital_a-l2`). Choose carefully: renaming later is an offboard + re-onboard ([UC-O3](#uc-o3--changing-a-hospitals-metadata-or-jwks-url)) |
| `client_name` | Human-readable name (shown in KC admin) |
| `organization_reference` | Canonical FHIR `Organization` reference URL — embedded by the AS in every token as `extensions.umzhconnect.organization_reference`; resource servers use it for consent lookup |
| `fhir_url` | Base URL of the hospital's own FHIR server (recorded for reference; not written into `aud` — see [ADR 0003](../adr/0003-constant-ecosystem-audience.md)) |
| `jwks_url` | Public HTTPS endpoint where the hospital publishes the JWKS for its L2 signing key. Must be reachable from Keycloak |
| `auth_level` | Must be `"L2"` — this field (not the directory or filename) is what routes the file into the L2 client map; a `check "known_auth_level"` block hard-fails `apply` if any `config/clients/*.yaml` file has a value other than `"L1"`/`"L2"` |

**Steps:**
1. Create a YAML file with the six fields above — recommended filename
   `{client_id}.yaml` (e.g. `hospital_a-l2.yaml`), though Terraform only
   reads the `client_id` field, never the filename — in your environment's
   hospital config location: the local docker-compose demo's
   `keycloak/config/clients/`, or your deployment repo's equivalent
   directory modeled on [`./argocd-template`](../../argocd-template) (see
   "Where hospital/scope config actually lives" above).
2. PR review and merge, in whichever repo that file lives.
3. `terraform apply` (see [UC-O4](#uc-o4--rolling-out-a-config-change-per-environment)
   for how this happens per environment). Terraform creates the KC client
   named by `client_id` with service account, `private_key_jwt` auth against
   the registered `jwks_url`, every scope from `config/scopes.yaml` registered
   as optional (none assigned by default — see [UC-O2](#uc-o2--adding-or-removing-a-realm-scope)),
   and the four protocol mappers (`client_id`, org reference, FHIR context,
   ecosystem audience).
4. Verify: the hospital acquires a token with its `client_id` and a
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

### UC-O1a — Hospital generates its L2 signing key and JWKS

Before a hospital can be onboarded ([UC-O1](#uc-o1--onboarding-a-new-hospital)),
it must generate its own RSA key pair and publish the public half as a JWKS
document at a stable, HTTPS-reachable `jwks_url`. This is entirely the
hospital's responsibility — the platform operator never sees or handles the
private key.

**Actor:** hospital (joining or rotating)
**Trigger:** onboarding ([UC-O1](#uc-o1--onboarding-a-new-hospital)) or key
rotation ([UC-L1](#uc-l1--hospital-rotates-its-l2-signing-key))

**Requirements the key and JWKS must satisfy** (enforced by the KC client's
`client-jwt` authenticator, [`clients.tf`](../../keycloak/terraform/clients.tf)):

- **Key type/size:** RSA, 2048 bits minimum.
- **Algorithm:** `RS256`. Keycloak's `private_key_jwt` verification defaults
  to RS256 when no `token.endpoint.auth.signing.alg` override is configured —
  this repo does not configure one, so RS256 is required.
- **`kid`:** every key in the JWKS must carry a unique `kid`. The `kid` in the
  client assertion's JWT header must match a `kid` present in the JWKS at
  verification time.
- **Format:** a standard JWKS document (`{"keys": [...]}`) containing only
  the **public** key material (`n`, `e`, `kty`, `use`, `kid`, `alg`) — never
  the private key.
- **Endpoint:** `jwks_url` must be a stable HTTPS URL, publicly reachable from
  Keycloak, that always serves the current JWKS (including any overlapping
  old key during rotation — see [UC-L1](#uc-l1--hospital-rotates-its-l2-signing-key)).
  Keycloak fetches and caches this on demand; there's no push/registration
  step beyond giving the operator this URL.

**Steps (hospital side):**
1. Generate an RSA-2048 key pair with `openssl` (present on macOS/Linux by
   default):
   ```sh
   openssl genrsa -out l2-signing.key 2048
   ```
2. Convert the private key to a public JWK, and build a JWKS from it, using
   [`step`](https://smallstep.com/docs/step-cli/) (`brew install step`):
   ```sh
   KID="l2-signing-$(date +%Y%m%d)"   # any unique id; must be unique per key in the JWKS

   # Derive the public JWK from the private key PEM. The second output file
   # (a private JWK) isn't used for anything — signing uses l2-signing.key
   # directly — so it's written to a throwaway path and discarded.
   step crypto jwk create l2-signing.pub.json /tmp/l2-signing.priv.json \
     --from-pem l2-signing.key --kid "$KID" --use sig --alg RS256 \
     --no-password --insecure
   rm -f /tmp/l2-signing.priv.json

   # Wrap the public JWK in a JWKS document ({"keys": [...]})
   echo '{"keys":[]}' > l2-signing.jwks.json
   step crypto jwk keyset add l2-signing.jwks.json < l2-signing.pub.json
   rm -f l2-signing.pub.json
   ```
   Result: `l2-signing.jwks.json` contains only public key material (`n`,
   `e`, `kty`, `use`, `kid`, `alg`) — the local demo fixture at
   [`keys/`](../../keys/README.md) shows the same shape for
   `*.jwks.json`. Any other JOSE/JWT library (e.g. `jose`, `python-jose`,
   `jwcrypto`) can produce an equivalent JWKS directly from the PEM public
   key if `step` isn't available.
3. Publish `l2-signing.jwks.json` at a stable HTTPS endpoint on
   infrastructure the hospital controls (e.g. behind its API gateway) — this
   becomes the `jwks_url` value it hands to the platform operator for
   [UC-O1](#uc-o1--onboarding-a-new-hospital) or
   [UC-O3](#uc-o3--changing-a-hospitals-metadata-or-jwks-url).
4. Keep `l2-signing.key` secret, never publish or transmit it — it signs
   `private_key_jwt` client assertions (RFC 7523) directly and is never sent
   to Keycloak or the platform operator.

**Postcondition:** hospital holds a private key and has a `jwks_url` ready to
give the platform operator for onboarding.

**Note:** this is a one-time setup per key generation, repeated on every
rotation ([UC-L1](#uc-l1--hospital-rotates-its-l2-signing-key)) — not a
per-request step. The hospital's own signing code loads the same private key
for every client assertion until the next rotation.

---

### UC-O2 — Adding or removing a realm scope

A new resource type joins the data-sharing model (new SMART scope), or a scope
is retired.

**Actor:** platform operator
**Trigger:** IG / data-sharing model change

**Steps:**
1. Edit `scopes.yaml` in your environment's config location (the local
   docker-compose demo's `keycloak/config/scopes.yaml`, or your deployment
   repo's equivalent modeled on [`./argocd-template`](../../argocd-template) —
   see "Where hospital/scope config actually lives" above): add or remove an
   entry under `scopes`. Every scope is registered on every hospital client
   as an optional scope — requestable explicitly via the `scope` parameter,
   never included unless requested.
2. PR review and merge, in whichever repo that file lives.
3. `terraform apply` — new scopes are created and registered; removed entries
   are destroyed together with their client assignments.

**Postcondition:** subsequently issued tokens reflect the change. Tokens
issued before the apply keep the old scope set until expiry (max 300 s).

**Caution:** scope changes are realm-wide — a new scope becomes requestable
by *every* hospital, and any hospital's existing integration that already
requests a now-removed scope will get `invalid_scope` on its next token
request. There is no per-hospital scope assignment (see "Requests you must
decline" above).

---

### UC-O3 — Changing a hospital's metadata or JWKS URL

A hospital changes a property of its registration — most commonly the
`jwks_url` (key endpoint moved), or `organization_reference` / display name.

**Actor:** platform operator, on request of the hospital
**Trigger:** infrastructure change, org metadata update

**Steps:**
1. Edit the hospital's L2 file in `config/clients/` in your environment's
   hospital config location (see "Where hospital/scope config actually lives" above).
2. PR review and merge, in whichever repo that file lives.
3. `terraform apply` — the KC client is updated in place.

**Postcondition:** Keycloak uses the new metadata immediately. If `jwks_url`
changed, Keycloak fetches the JWKS from the new URL on the next token request.

**Note:** changing `client_id` is a rename, not an in-place update. Treat it
as offboarding the old identity ([UC-L2](#uc-l2--offboarding-a-hospital))
plus onboarding a new one ([UC-O1](#uc-o1--onboarding-a-new-hospital)),
coordinated with the hospital so its systems switch `client_id` at the
cutover.

---

### UC-O4 — Rolling out a config change per environment

How a merged config change (hospital YAML, scopes YAML, or `.tf` change)
actually reaches a running Keycloak. The mechanism differs depending on
whether the change is config-only or touches Terraform logic — see "Where
hospital/scope config actually lives" above.

**Actor:** platform operator / CI

| Change | Kubernetes (ArgoCD or similar) | Local (docker-compose), for development |
|--------|--------------------------------|------------------------------------------|
| Hospital or scope YAML only | Edit the file in your deployment repo's config directory and merge. If your deployment uses ArgoCD (or an equivalent GitOps controller) watching that repo, it detects the commit on its own and re-triggers the configurator Job, which re-runs `terraform apply` with state persisted on a PVC — no image rebuild needed. See [`argocd-template/`](../../argocd-template) for the manifest shape (`keycloak_config/`, `kustomization.yaml`'s `configMapGenerator`, the PostSync Job) | `docker compose up keycloak-config`, or `terraform -chdir=keycloak/terraform apply` with `TF_VAR_keycloak_url=http://localhost:8180` |
| `.tf` logic (`keycloak/terraform/**`) | Publish a new `tf-config` image from this repo, then update your deployment repo's manifest to reference the new image tag/digest (manually, or via whatever image-automation your deployment uses — outside this repo's scope) so the configurator Job picks it up on its next run | Same as above — `docker compose up --build keycloak-config` picks up the local `.tf` changes directly |

Production deployments are not yet standardized by this repo; the delivery
target is a config snapshot for `umzhconnect/umzhconnect-auth` (pending).

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
2. Create a file in `config/clients/` (in the local docker-compose demo's
   `keycloak/config/clients/`, or your deployment repo's equivalent — see
   "Where hospital/scope config actually lives" above) with `client_id`
   (convention: `{hospital_name}-l1`), `client_name`, `organization_reference`,
   `fhir_url`, and `auth_level: "L1"` — see [the directory's
   README](../../keycloak/config/clients/README.md) for the field
   schema. Independent of the L2 file for the same hospital: it may have an
   L1 file, an L2 file, both, or neither, in any order.
3. PR review and merge, in whichever repo that file lives.
4. `terraform apply` — creates the KC client named by `client_id` with a
   Keycloak-generated `client_secret`, `client_credentials` grant, the same
   default/optional scopes and mapper set as the L2 client (org reference,
   FHIR context, ecosystem audience), plus `extensions.umzhconnect.auth_level`
   sourced from the file's `auth_level` field (`"L1"`).
5. Hand the generated `client_secret` to the hospital (see [ADR
   0004](../adr/0004-reinstate-l1-debug-client.md) for the relaxed-but-scoped
   secret-handling exception this client gets — it's still not to be reused
   as a general credential-handling precedent).
6. Verify: the hospital acquires a token per [technical.md
   UC-T8](technical.md#uc-t8--debug-client-acquires-an-l1-token) and confirms
   `extensions.umzhconnect.auth_level = "L1"`.

**Postcondition:** hospital can obtain L1 debug tokens alongside (or instead
of, if it hasn't onboarded L2 yet) its L2 client. Revoking L1 access mirrors
offboarding: delete the hospital's `config/clients/*.yaml` file with
`auth_level: "L1"` and `terraform apply` — this is independent of, and does not affect, the
hospital's L2 client.

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
1. Delete the hospital's L2 file from `config/clients/` in your environment's
   hospital config location (see "Where hospital/scope config actually
   lives" above). There is no allow-list or grants file to clean up
   elsewhere.
2. PR review and merge, in whichever repo that file lives.
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
4. Publish the image, then update your deployment repo's manifest to
   reference the new tag/digest (manually, or via whatever image-automation
   your deployment uses — see [`./argocd-template`](../../argocd-template)
   for the manifest shape) so it gets rolled out.
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
