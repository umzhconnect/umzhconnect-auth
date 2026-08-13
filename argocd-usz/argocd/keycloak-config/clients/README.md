# `keycloak-config/clients/*.yaml` — USZ test clients

One file per M2M client. `client_id` and `auth_level` come from the file
**content**, not the filename (the filename is a human convention: name it
after `client_id`). There is **no implicit access** — a client with no file
here has no Keycloak client and cannot obtain tokens.

## Onboarding a client (Approach 1)

1. Add a `<client_id>.yaml` file here.
2. Add its path to the `kc-clients` `configMapGenerator` in
   [`../../kustomization.yaml`](../../kustomization.yaml) — this is the one
   extra edit Approach 1 costs (kustomize can't glob a directory). Forgetting
   it means the file is silently not delivered.
3. Commit / open a PR. On the next ArgoCD sync the config ConfigMap's content
   hash changes, the PostSync Job re-runs, and `terraform apply` reconciles
   the new client. **No image build.**

(When the config graduates to a standalone data-as-code repo cloned at Job
runtime — Approach 4 — step 2 goes away; see the main README's "Migration to
Approach 4".)

## L2 (`private_key_jwt`) — the production default

```yaml
client_id: "example_client-l2"
client_name: "Example Client"
organization_reference: "https://fhir.example-client.example/fhir/Organization/ExampleClient"
fhir_url: "https://fhir.example-client.example/fhir"
jwks_url: "https://jwks.example-client.example/.well-known/jwks.json"
auth_level: "L2"
```

`auth_level` must be `"L2"`. Keycloak fetches the client's public keys from
`jwks_url` to verify its signed assertions, so that URL must be reachable
from the cluster.

## L1 (`client_secret`) — opt-in debug client only

L1 files are ignored unless the Job sets `TF_VAR_allow_l1_debug_clients=true`
(see [`../../keycloak-config-job.yaml`](../../keycloak-config-job.yaml)). See
[ADR 0004](../../../../docs/adr/0004-reinstate-l1-debug-client.md). Leave the
default (`false`) unless a hospital specifically needs the debug path.

## Removing / disabling

- Delete the file (+ its `kc-clients` entry) → destroys the KC client.
- `enabled: false` in the file → keeps the client (and, for L1, its secret)
  but disables it.

Replace `example_client-l2.yaml` with the real USZ test client(s) before
deploying.
