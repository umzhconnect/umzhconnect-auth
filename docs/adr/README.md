# Architecture Decision Records

This directory contains the Architecture Decision Records (ADRs) for the UMZH Connect Authentication Server.

## What is an ADR?

An ADR documents a significant architectural decision: the context that forced the choice, the decision itself, and its consequences — including what was explicitly ruled out and why. It is a permanent record of the reasoning behind the design, not just the outcome.

ADRs are especially useful for capturing **deferred decisions** and **conscious non-decisions**: cases where a feature or approach was considered but deliberately not implemented yet, along with the condition under which it should be revisited.

## Format

Each ADR is a single Markdown file named `NNNN-short-title.md` with the following sections:

| Section | Purpose |
|---------|---------|
| **Status** | `Accepted`, `Proposed`, `Deprecated`, or `Superseded by [NNNN]` |
| **Context** | The situation and forces that made a decision necessary |
| **Decision** | What was decided (or explicitly deferred, and why) |
| **Consequences** | What becomes easier, harder, or constrained as a result |
| **Revisit when** | *(for deferred decisions)* The concrete condition that should trigger re-evaluation |

## When to write an ADR

Write an ADR when:

- A non-obvious architectural choice is made (and someone will reasonably ask "why not X?")
- A feature or approach is explicitly deferred — not forgotten, but consciously parked
- An existing decision is reversed or superseded

Do **not** write an ADR for implementation details, routine config changes, or decisions that are fully self-evident from the code.

## Index

| ID | Title | Status |
|----|-------|--------|
| [0001](0001-defer-auth-level-claim.md) | Defer `auth_level` claim until L3 is introduced | Accepted |
| [0002](0002-one-client-per-hospital.md) | One Keycloak client per hospital | Accepted |
| [0003](0003-defer-scope-and-audience-enforcement.md) | Defer scope and audience enforcement to downstream | Superseded by [0004](0004-rfc8707-resource-indicators.md) |
| [0004](0004-rfc8707-resource-indicators.md) | RFC 8707 resource indicators for audience binding | Superseded by [0005](0005-d2-named-aud-scopes.md) |
| [0005](0005-d2-named-aud-scopes.md) | D2 named `aud:` scopes for audience binding | Accepted |
