# Development execution and integration policy

This document explains how implementation work is batched between accepted `main` boundaries. It is a stable execution-policy companion to `AGENTS.md`; live stage status remains in Issue #86 and natural-owner issues.

## Core distinction

An implementation stage is not automatically a merge boundary.

The default unit of integration is an **evidence milestone**: the largest coherent batch that can be completed and validated at E1/E2 before the next missing fact genuinely requires accepted `main`, LAB, provider mutation, or a release boundary.

```text
accepted main
 -> draft integration PR
 -> several E1/E2-completable implementation stages
 -> deliberate exact-head CI checkpoint(s)
 -> one milestone merge
 -> accepted green main
 -> main-only LAB/provider/release boundary when actually required
```

Do not turn `main` into a progress ledger.

## Current product milestone

Until Issue #86 changes the gate, keep these adjacent changes in the same draft integration PR:

```text
production Android lifecycle
 -> durable external client credentials
 -> bounded exact-address Mesh ingress
 -> DNS/readiness implementation
 -> TCP-only client hardening
```

Finish every E1/E2 fact that can be proven without DEVICE-1 before crossing the next `main -> LAB` boundary.

Root-policy, One Agent/DNS, exact Mesh-address behavior, reboot/background survival and cellular loss/recovery remain physical facts where code evidence is insufficient.

## Commit and push granularity

Prepare related edits together. A remote push should represent one coherent reviewable batch, not an editor save point.

When GitHub APIs are used for several files, prefer one Git tree, one commit and one ref update.

## CI granularity

Ordinary PR `synchronize` pushes do **not** trigger CI. This prevents workflow-run noise while a draft integration milestone is still being assembled.

Full CI is intentionally created only by:

```text
workflow_dispatch on an exact checkpoint head
ready_for_review on the final milestone head
push to protected main after merge
```

Before merge the PR must be ready for review and complete required CI must pass on the exact head.

If a validated ready-for-review head changes, move the PR back to Draft, accumulate the correction batch, then mark it ready again. Do not reintroduce per-push `synchronize` CI merely to automate that transition.

## Main and LAB

Development LAB accepts only an exact accepted green PRODUCT `main` SHA. PR branches are not LAB source identity.

Therefore the merge decision is:

```text
Can the next required fact be established correctly at E1/E2?
  YES -> keep working in the draft integration PR; do not merge for progress.
  NO  -> finish all independent E1/E2 work, validate the exact head, merge once,
         verify main, then request the bounded main-only physical fact.
```

A LAB run is not triggered merely because a PR merged. Issue #86 must identify the physical fact and why it is required.

## Physical correction loop

When a main-only physical run reveals a defect:

```text
typed/redacted physical finding
 -> bounded correction batch on a branch
 -> deliberate exact-head CI
 -> one merge
 -> main-only physical re-proof only when necessary
```

Never choose fwmarks, RPDB priorities, Mesh identity behavior, DNS ownership or Android/VPN interaction by guess merely to avoid a physical checkpoint.
