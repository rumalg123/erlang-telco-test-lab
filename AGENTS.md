# Code Quality & Refactoring

## Guiding Principles

This repository is intended to become a production-grade telecom platform.
Every change should improve maintainability without changing behaviour.

Always follow:

- DRY (Don't Repeat Yourself)
- SOLID
- KISS
- YAGNI
- Single Source of Truth

Prefer fixing root causes over adding workarounds.

---

## Required Refactoring

Whenever modifying existing code, actively look for opportunities to remove technical debt.

### Duplicate Code

- Never duplicate logic.
- Extract reusable code into shared modules or helper functions.
- If similar logic exists more than once, consolidate it.

### Magic Numbers

Replace unexplained numeric literals with named constants or macros.

Examples include:

- Timeouts
- Retry counts
- SCTP parameters
- SCCP values
- TCAP values
- MAP operation codes
- Buffer sizes
- Ports
- Protocol identifiers

### Repeated Literals

Avoid repeating:

- atoms
- strings
- binaries
- protocol names
- log messages
- error messages

Define them once and reuse them.

### Configuration

Never hardcode:

- IP addresses
- Ports
- Timeouts
- Paths
- Feature flags
- Operator-specific values

Move them into configuration whenever practical.

### State Values

Centralize repeated state values, enums, atoms and protocol constants into shared definitions.

### Functions

Prefer:

- small functions
- single responsibility
- descriptive names

Avoid:

- deeply nested case statements
- long if/case chains
- duplicated pattern matching
- excessive boolean flags

### Dead Code

Remove:

- unused functions
- unused variables
- unreachable code
- obsolete comments
- commented-out code

Never leave dead code behind.

---

## Behaviour Preservation

Refactoring must never change externally observable behaviour.

Maintain:

- protocol compatibility
- binary compatibility
- timing characteristics where applicable
- public APIs

Run existing tests after refactoring.

If tests are missing and practical, add them.

---

## Continuous Improvement

Leave every touched file in a better state than you found it.

When working in a file:

- reduce duplication
- simplify logic
- improve naming
- improve readability
- reduce complexity
- remove technical debt
- improve maintainability

Avoid cosmetic refactoring that creates unnecessary review noise.

---

## Large Changes

For large refactors:

- keep commits focused
- group related changes
- explain the motivation
- explain any trade-offs

If a refactoring is high risk, stop and explain why instead of guessing.

---

## Code Review Checklist

Before considering a task complete, verify:

- No duplicate code introduced
- No new magic numbers
- No unnecessary hardcoded literals
- No dead code
- No unnecessary complexity
- No compiler warnings
- All tests pass
- Code remains idiomatic Erlang
- Behaviour is unchanged

# Preferred Workflow

Before writing code:

1. Understand the existing architecture.
2. Search for existing implementations before creating new ones.
3. Reuse existing abstractions whenever possible.
4. Avoid introducing duplicate implementations.
5. Prefer extending existing modules over creating new ones.

When implementing:

- Make the smallest correct change.
- Keep changes reviewable.
- Preserve backward compatibility.
- Follow existing project conventions.

After implementation:

- Compile.
- Run affected tests.
- Remove dead code.
- Eliminate duplication introduced during implementation.
- Verify no warnings remain.