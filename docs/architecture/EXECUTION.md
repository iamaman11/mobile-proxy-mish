# Development execution and integration policy

This document explains how implementation work is batched between accepted `main` boundaries. It is a stable execution-policy companion to `AGENTS.md`; live stage status remains in the active execution checkpoint — currently Issue #135 — plus the relevant natural-owner issues.

Issue #134 is the current master PRODUCT/architecture/research plan for the hardening milestone. Issue #86 is historical M1 / E3-E4 / release-acceptance context and is read only when a concrete acceptance or release-lineage fact requires it.

## Core distinction

Three units are intentionally different:

```text
commit batch != review slice != main evidence milestone
```

A small implementation stage is not automatically a PR, and a review PR is not automatically a `main` merge boundary.

Canonical flow:

```text
accepted main
 -> milestone integration branch / PR named by the active checkpoint
 -> short-lived slice branch
 -> coherent commit batch(es)
 -> slice PR -> current integration branch
 -> repeat bounded slices
 -> deliberate integration CI when justified
 -> final milestone ready-for-review exact-head CI
 -> one milestone merge to main
 -> accepted green main
 -> main-only LAB/provider/release boundary when actually required
```

Do not turn `main` into a progress ledger and do not turn the milestone PR into the everyday working diff.

## Current product milestone

The active execution checkpoint defines the current stage and current integration pointer. At present #135 implements the #134 P0-P11 hardening/product plan and starts with bounded P0 recovery attribution.

The checkpoint is intentionally compact. Detailed semantic contracts stay in natural-owner issues and architecture docs; detailed code-review history stays in slice PRs.

## Commit-only phase

A slice begins as a short-lived branch from the exact current integration/working head named by the active checkpoint.

While implementation is incomplete, use coherent commits without opening a PR for every edit. A remote push should represent a reviewable batch, not an editor save point.

When GitHub APIs are used for several files, prefer one Git tree, one commit and one ref update.

## Slice PR boundary

Create a slice PR when the change is coherent enough to review independently. Its base is the current integration branch named by the active checkpoint, not `main`, unless the checkpoint explicitly records a different boundary.

Default slice budget:

- one natural owner;
- at most one required adapter/composition boundary;
- direct tests for those semantics.

A slice that crosses more than two semantic owners or grows beyond roughly eight implementation/test files should be split unless the coupling is inseparable and documented.

Only one slice is active by default. The active checkpoint records any explicit dependency reason for parallel slices.

Slice PRs provide durable context checkpoints and must state owner, goal, base SHA, invariants, touched boundaries, tests/evidence, what remains unproven and follow-up work.

After review, squash-merge the slice into the current integration branch. That synchronization does not trigger a `main` merge, LAB run or ordinary CI cycle.

## Context budget

During slice work, an executor should load only:

```text
active execution checkpoint (currently #135)
current slice PR/branch
only the referenced #134 finding/stage when needed
relevant natural-owner issue/contracts
one required adapter boundary
corresponding direct tests
```

Do not load by default:

```text
entire #86 history
entire #134 comment history
entire milestone diff
unrelated owner issues
all architecture documents
all CI history
```

Fetch older history only when a concrete claim depends on it.

After each slice merge, the active checkpoint records the completed slice, next/current slice, current integration pointer, evidence, blocker and next decision. This prevents chat/session memory from becoming a hidden source of truth.

## CI granularity

Ordinary PR `synchronize` pushes do **not** trigger CI.

Full CI is intentionally created only by:

```text
workflow_dispatch on an exact checkpoint head when justified
ready_for_review on the final milestone head
push to protected main after merge
```

Slice PR existence alone is not a CI boundary. A deliberate manual checkpoint is justified when the slice changes a material cross-language/build contract or otherwise cannot be safely validated by review plus direct tests alone.

Before the milestone merge, the milestone PR must be ready for review and complete required CI must pass on the exact head. If that head later changes, return it to Draft, batch corrections, then mark ready again.

## Diagnostic / local-agent escalation

When a material implementation decision depends on a DEVICE-1, Windows, Cloudflare One Client/Mesh, ADB, Magisk/root, real network, timing, resource or other runtime fact that source code and hosted CI cannot establish correctly, do not guess.

Use the smallest experiment that resolves the exact missing fact:

```text
material ambiguity
 -> identify exact missing fact
 -> bounded read-only/diagnostic local-agent experiment
 -> exact baseline + sanitized evidence
 -> implementation decision
```

The local/Windows agent is a diagnostic/physical executor, not a second state authority. Its diagnostic results do not become E3/E4 acceptance unless they are produced through the formal immutable-artifact acceptance path. Relevant sanitized conclusions must be recorded back in the active checkpoint or appropriate owner/master-plan issue.

## Main and LAB

Formal Development LAB accepts only an exact accepted green PRODUCT `main` SHA. PR and integration branches are not LAB/E3/E4 source identity.

A bounded diagnostic local-agent run may still be used earlier when the active checkpoint requires a physical/runtime fact for an implementation decision; such a run is diagnostic only and must not be promoted to formal acceptance.

Therefore the merge decision is:

```text
Can the next required fact be established correctly at E1/E2?
  YES -> keep working through bounded slices on the current integration branch.
  NO, but a diagnostic fact is enough -> request the smallest bounded local-agent diagnostic and record it as diagnostic evidence only.
  NO, formal accepted-main evidence is required -> finish all independent E1/E2 slices,
       validate the final exact milestone head, merge once, verify main,
       then request the bounded main-only LAB/provider/release fact.
```

A LAB run is not triggered merely because a PR merged. The active checkpoint must identify the physical fact and why it is required.

## Physical correction loop

When a main-only physical run or bounded diagnostic run reveals a defect:

```text
typed/redacted physical finding
 -> bounded correction slice
 -> slice review
 -> deliberate exact-head CI when justified
 -> one milestone merge
 -> main-only physical re-proof only when the stronger acceptance fact must be re-established
```

Never choose fwmarks, RPDB priorities, Mesh identity behavior, DNS ownership, Android/VPN interaction, timeout values, capacity changes or recovery policy by guess merely to avoid a physical checkpoint.
