# 0003 — No default scopes in grants files

**Status:** Accepted  
**Date:** 2026-06-19  
**Authors:** Trifork

---

## Context

During the design of the grant-based client config model (see ADR 0002), the question arose whether a FHIR server operator could define a set of default scopes in their grants file — scopes that would apply automatically to any registered app for which no explicit grant entry exists. The intent would be to reduce configuration friction for common baseline access across a well-established network.

---

## Decision

**No default scopes.** Every grant must be explicit. The invariant

> no entry in a grants file → no KC client generated → no token access

is preserved without exception. A registered app with no grant entry for a given FHIR server has zero access to that server, not baseline access.

---

## Consequences

- Every bilateral access relationship requires a deliberate entry in the target's `config/grants/{server_key}.yaml`.
- The audit question "why does this app have access to this FHIR server?" always has a one-line answer traceable to a specific YAML entry and a PR.
- `scripts/validate-grants.py` remains simple: the grant graph is fully explicit and requires no inheritance resolution.
- Onboarding a new app requires the calling org to open PRs against each target org's grants file — this friction is intentional, not a defect.

## Why defaults were rejected

- **Implicit grants are the wrong baseline for clinical data.** Access should exist because an operator said yes, not because nobody said no.
- **Defaults break the no-entry-means-no-access invariant**, introducing a hidden third state that is harder to audit and reason about.
- **Misconfiguration risk.** A new app registration that automatically inherits access to all FHIR servers in the network creates a wide implicit surface. In the current explicit model, a misconfigured or malicious app registration is inert until a target org actively grants it access.
- **Consistency.** Every KC client in the realm exists because of a specific grants entry. Defaults would mean some clients exist for reasons that are not visible in the grants files.
