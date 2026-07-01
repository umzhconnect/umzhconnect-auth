# ADR 0006 — `allowed_clients`: target hospital controls inbound access

**Status:** Accepted — amends [ADR 0005](0005-d2-named-aud-scopes.md) (D2 named `aud:` scopes)

---

## Context

ADR 0005 introduced D2 audience binding using named `aud:` scopes. The allow-list field was named `allowed_targets` and placed on the *requesting* hospital: hospital-a declaring `allowed_targets: [hospital-b]` meant "hospital-a is permitted to target hospital-b."

This framing puts access control in the wrong place. Hospital-b has no visibility into — and no ability to modify — who may target it. The authorization decision (who may call my FHIR server) belongs to the resource owner, which is the target hospital, not the caller.

---

## Decision

Rename `allowed_targets` to `allowed_clients` and invert ownership: each hospital's YAML now declares which clients are permitted to request a token with *that hospital* as audience.

```yaml
# hospital-b.yaml — hospital-b decides who may call it
org_id: "hospital-b"
...
allowed_clients:
  - "hospital-a"
  - "hospital-c"
```

Terraform (`scopes.tf`) now derives the optional scope assignment from the target's perspective: for each client X, collect all hospitals Y where X appears in Y's `allowed_clients`, and assign `aud:Y` as an optional scope on X's KC client.

```hcl
optional_scopes = concat(
  [for s in local._scopes_config.optional_scopes : s.name],
  [for target_id, target in local.hospitals : "aud:${target_id}"
    if contains(lookup(target, "allowed_clients", []), each.key)]
)
```

The `aud:` scope naming convention, the audience mapper, and the token `aud` value are unchanged.

---

## Consequences

- The target hospital's YAML file is the single authoritative source for who may call it. Onboarding a new caller requires editing the target's YAML, not the caller's.
- Revoking a caller's access is a one-file change (remove from target's `allowed_clients`), with no risk of leaving a stale reference in the caller's file.
- The field name `allowed_clients` reflects the KC term (KC `client_id`) and the direction of the permission grant unambiguously.
- Omitting `allowed_clients` (or leaving it empty) means no client can request a token targeting that hospital — consistent with the existing "no implicit access" rule.
- The graph is semantically equivalent to the `allowed_targets` encoding for any symmetric configuration; only the ownership model changes.

---

## Revisit when

- The Policy Server milestone is reached — at that point, per-(caller, target) scope grants will layer on top of this allow-list, and the config model may need to express finer-grained permissions than a simple client list.
