# Development execution and integration policy

This document explains how implementation work is batched between accepted `main` boundaries. It is a stable execution-policy companion to `AGENTS.md`; live stage status remains in Issue #86 and natural-owner issues.

## Core distinction

Three units are intentionally different:

```text
commit batch != review slice != main evidence milestone
```

A small implementation stage is not automatically a PR, and a review PR is not automatically a `main` merge boundary.

Canonical flow:

```text
accepted main
 -> Draft M1 integration branch / PR
 -> short-lived slice branch
 -> coherent commit batch(es)
 -> slice PR -> M1 integration branch
 -> repeat bounded slices
 -> deliberate integration CI when justified
 -> final M1 ready-for-review exact-head CI
 -> one milestone merge to main
 -> accepted green main
 -> main-only LAB/provider/release boundary when actually required
```

Do not turn `main` into a progress ledger and do not turn the final M1 PR into the everyday working diff.

## Current product milestone

Until Issue #86 changes the gate, M1 contains:

```text
production Android lifecycle
 -> durable external client credentials
 -> bounded exact-address Mesh ingress
 -> DNS/readiness implementation
 -> TCP-only client hardening
```

These remain one eventual `main` evidence milestone, but they should be implemented and audited as bounded review slices.

## Commit-only phase

A slice begins as a short-lived branch from the exact current M1 integration head.

While implementation is incomplete, use coherent commits without opening a PR for every edit. A remote push should represent a reviewable batch, not an editor save point.

When GitHub APIs are used for several files, prefer one Git tree, one commit and one ref update.

## Slice PR boundary

Create a slice PR when the change is coherent enough to review independently. Its base is the M1 integration branch, not `main`.

Default slice budget:

- one natural owner;
- at most one required adapter/composition boundary;
- direct tests for those semantics.

A slice that crosses more than two semantic owners or grows beyond roughly eight implementation/test files should be split unless the coupling is inseparable and documented.

Only one slice is active by default. Slice PRs provide durable context checkpoints and must state owner, goal, base SHA, invariants, touched boundaries, tests/evidence, what remains unproven and follow-up work.

After review, squash-merge the slice into the integration branch. That synchronization does not trigger a `main` merge, LAB run or ordinary CI cycle.

## Context budget

During slice work, an executor should load only:

```text
#86 current checkpoint
current slice PR/branch
relevant natural-owner issue/contracts
one required adapter boundary
corresponding direct tests
```

The entire M1 diff is read only for final cross-slice integration review or when a concrete dependency requires it.

After each slice merge, #86 records the completed slice, next slice and current integration pointer. This prevents chat/session memory from becoming a hidden source of truth.

## CI granularity

Ordinary PR `synchronize` pushes do **not** trigger CI.

Full CI is intentionally created only by:

```text
workflow_dispatch on an exact checkpoint head when justified
ready_for_review on the final M1 head
push to protected main after merge
```

Slice PR existence alone is not a CI boundary. A deliberate manual checkpoint is justified when the slice changes a material cross-language/build contract or otherwise cannot be safely validated by review plus direct tests alone.

Before the M1 merge, the M1 PR must be ready for review and complete required CI must pass on the exact head. If that head later changes, return it to Draft, batch corrections, then mark ready again.

## Main and LAB

Development LAB accepts only an exact accepted green PRODUCT `main` SHA. PR and integration branches are not LAB source identity.

Therefore the merge decision is:

```text
Can the next required fact be established correctly at E1/E2?
  YES -> keep working through bounded slices on the M1 integration branch.
  NO  -> finish all independent E1/E2 slices, validate the final exact M1 head,
         merge once, verify main, then request the bounded main-only physical fact.
```

A LAB run is not triggered merely because a PR merged. Issue #86 must identify the physical fact and why it is required.

## Physical correction loop

When a main-only physical run reveals a defect:

```text
typed/redacted physical finding
 -> bounded correction slice
 -> slice review
 -> deliberate exact-head CI when justified
 -> one milestone merge
 -> main-only physical re-proof only when necessary
```

Never choose fwmarks, RPDB priorities, Mesh identity behavior, DNS ownership or Android/VPN interaction by guess merely to avoid a physical checkpoint.
