# `keycloak-config/clients/*.yaml` — USZ M2M clients

One file per M2M client. `client_id` and `auth_level` are read from the file
**content**, never from the filename. There is **no implicit access** — a
client with no file here has no Keycloak client and cannot obtain tokens.

## Client ID convention

`client_id` is an **opaque** identifier: a `cli_` prefix plus **6 base58
characters** (unambiguous alphabet — no `0 O I l`):

```
cli_AQcDTg     cli_V74JEo
```

- **Opaque, not derived from the org.** The organization identity travels
  separately as `organization_reference` (a FHIR `Organization` reference),
  which the AS stamps into the token as a trusted claim. Resource servers
  authorize on **that claim** — never by string-parsing the `client_id`.
- **Immutable.** The `client_id` appears in every token (`azp`, the `client_id`
  claim), the client's own auth config, and RS logic. Assign it once and never
  rename it — renaming breaks the client and everything downstream. Deleting the
  file is offboarding; there is no "rename".
- **6 base58 ≈ 35 bits (~38 billion values).** That's ample here: the `client_id`
  is not a secret (auth is a signed `private_key_jwt`, so it's not brute-forced),
  and collisions are negligible at this scale **and** hard-fail the apply via the
  duplicate-`client_id` precondition in `terraform/clients.tf`. Bump to 8 chars
  only if you ever expect 10k+ clients.

Generate a new one (cryptographically random):

```bash
python3 -c "import secrets;a='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';print('cli_'+''.join(secrets.choice(a) for _ in range(6)))"
```

## Filenames are by **org**, not by `client_id`

Because the `client_id` is opaque, name each file after the organization
(`usz.yaml`, `balgrist.yaml`) so the directory stays navigable. Terraform reads
the `client_id` from the file content, so the filename is purely a human
convenience — it does **not** have to match the `client_id`.

## Onboarding a client (Approach 1)

1. **Generate** a `client_id` (command above).
2. **Add** an `<org>.yaml` file here with that `client_id` (see the L2 shape below).
3. **List** its path in the `kc-clients` `configMapGenerator` in
   [`../../kustomization.yaml`](../../kustomization.yaml) — the one extra edit
   Approach 1 costs (kustomize can't glob a directory); forgetting it means the
   file is silently not delivered.
4. **Commit / open a PR.** On the next ArgoCD sync the ConfigMap's content hash
   changes, the PostSync Job re-runs, and `terraform apply` reconciles the new
   client. **No image build.**

(When the config graduates to a standalone data-as-code repo cloned at Job
runtime — Approach 4 — step 3 goes away; see the main README's "Migration to
Approach 4".)

## L2 (`private_key_jwt`) — the production default

```yaml
client_id: "cli_AQcDTg"
client_name: "University Hospital Zurich"
organization_reference: "https://registry-test.umzhconnect.ch/fhir/Organization/usz"
fhir_url: "https://api.usz.ch/clinical-orders/v1/fhir"
jwks_url: "https://api.usz.ch/clinical-orders/v1/.well-known/jwks.json"
auth_level: "L2"
```

`auth_level` must be `"L2"`. Keycloak fetches the client's public keys from
`jwks_url` to verify its signed assertions, so that URL must be reachable from
the cluster.

## L1 (`client_secret`) — opt-in debug client only

L1 files are ignored unless the Job sets `TF_VAR_allow_l1_debug_clients=true`
(see [`../../keycloak-config-job.yaml`](../../keycloak-config-job.yaml)). See
[ADR 0004](../../../../docs/adr/0004-reinstate-l1-debug-client.md). Leave the
default (`false`) unless a hospital specifically needs the debug path.

## Removing / disabling

- Delete the file (+ its `kc-clients` entry) → destroys the KC client (and, for
  L1, its secret). This is offboarding.
- `enabled: false` in the file → keeps the client but disables it.
