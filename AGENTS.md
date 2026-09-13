# Executor policy

GitHub is the durable source of truth. Chat handoffs, copied status text, CI summaries and generated artifacts are not substitutes for a fresh GitHub baseline.

## Required startup baseline

Before planning or mutating:

1. read fresh protected `main`;
2. read the current cross-component execution tracker (#86);
3. inspect the current M1 integration PR and exact integration-trunk head;
4. read the current slice PR when one exists;
5. read only the natural-owner issue/contracts and implementation files touched by that slice;
6. distinguish current facts from historical evidence.

One fresh baseline opens one bounded mutation window. Do not re-baseline after every write performed inside that same bounded window.

## Three integration levels

Do not confuse a coding batch, a review boundary and a `main` merge boundary.

### 1. Commit-only work

While one bounded slice is still being implemented, work on a short-lived slice branch created from the current M1 integration-trunk head.

A commit should be coherent and reviewable. A remote push is not an editor save point. When several repository files must change through GitHub, prefer:

```text
prepare all edits
 -> one Git tree
 -> one commit
 -> one branch-ref update
```

Do not open a PR merely because one or two files changed.

### 2. Slice review PR

Open a slice PR only when that bounded slice is coherent enough to audit as a unit.

The slice PR targets the M1 integration branch, **not `main`**. It should be opened review-ready (non-Draft) only after the implementation slice itself is coherent. Ordinary `opened` and `synchronize` events do not trigger the full CI workflow under the current CI contract.

A normal slice contains at most:

- one natural owner;
- one necessary platform/vendor/composition adapter;
- the direct tests for that owner/adapter boundary.

If a proposed slice touches more than two semantic owners, or grows beyond roughly eight implementation/test files, split it unless the coupling is technically inseparable and the PR explains why.

Exactly one implementation slice should be active at a time unless #86 records an explicit dependency reason for parallel slices.

Each slice PR body must record:

```text
OWNER
GOAL
BASE_SHA
INVARIANTS
FILES / BOUNDARIES TOUCHED
TESTS / EVIDENCE
NOT PROVEN
FOLLOW-UP
```

Detailed code review happens at the slice PR. After it is accepted, squash-merge it into the M1 integration branch and delete the short-lived slice branch. Updating the integration branch does not itself justify a `main` merge or LAB run.

### 3. Milestone PR to main

The current M1 integration PR is a container for accepted slice results and the final cross-slice integration review. It is **not** the normal working diff for day-to-day implementation.

Keep the M1 PR Draft while slices are still being assembled. Merge to `main` only when at least one of these is true:

- the coherent integration milestone is complete as far as E1/E2 can prove it;
- the next missing fact can only be obtained from a main-only LAB/provider/release path;
- a natural-owner contract explicitly requires accepted `main`;
- the change must establish a protected-main compatibility boundary before further work.

Do not merge to `main` merely because one internal implementation stage or slice completed.

## Context-budget rule

The executor must not rely on remembering the whole integration diff.

During implementation, the active working set is:

```text
#86 current checkpoint
+ current slice PR/branch
+ one natural-owner contract
+ one adapter boundary when required
+ direct tests
```

Do not reload or reason line-by-line over the entire M1 PR unless performing final integration review.

After each slice merge, #86 must update `COMPLETED_SLICES`, `CURRENT_SLICE` and the current integration head/PR pointer. Slice PR descriptions are durable implementation checkpoints; chat memory is not.

## CI rule

CI is deliberate evidence, not an edit loop.

Ordinary PR `synchronize` pushes do **not** trigger the CI workflow. Full CI is allowed only through deliberate evidence boundaries:

- `workflow_dispatch` on an exact meaningful checkpoint head when hosted build/test evidence is genuinely needed;
- `ready_for_review` on the final M1 PR head;
- `push` to protected `main` after merge.

A slice PR does not receive full CI merely because it exists. Use a manual exact-head checkpoint only when the slice has material build/integration uncertainty that cannot be closed by code review and direct tests alone, for example Rust/UniFFI/Gradle contract changes or another cross-language/toolchain boundary.

Before the M1 merge, mark the M1 PR ready for review and require complete CI PASS on the exact PR head.

If the M1 head changes after a ready-for-review validation, return it to Draft, accumulate the correction batch, then mark it ready again for a fresh exact-head CI.

## Main rule

`main` is an accepted integration/evidence boundary. Do not use `main` as a scratch integration branch or progress ledger.

Record intermediate progress in #86, slice PRs and the Draft M1 PR.

## Development LAB rule

Development LAB consumes an exact accepted green PRODUCT `main` SHA. Never claim LAB evidence from a PR or integration branch.

Do not create a new LAB candidate merely because a slice or M1 PR completed.

Run development LAB only when #86 identifies a physical fact that cannot be legitimately established by E1/E2 evidence and that fact is needed for the next implementation decision or acceptance gate.

Batch all code work that does not require that physical fact before crossing the `main -> LAB` boundary.

## Physical correction loop

When LAB reveals a physical defect, use:

```text
typed physical finding
 -> bounded correction slice
 -> slice review
 -> deliberate exact-head CI when required
 -> one milestone merge
 -> main-only LAB if the physical fact must be re-proven
```

Do not merge each attempted line-level correction separately. Never guess a physical fact merely to avoid LAB.

## Evidence law

```text
E1 < E2 < E3 < E4
```

Weaker evidence must never close a stronger claim. LAB, CI logs, README text, generated artifacts and chat summaries are not mutable product-state authorities.

## Architecture law

Preserve:

```text
one fact -> one natural owner -> one write path -> one observation path
```

Prefer an existing natural owner plus one narrow adapter.

Do not introduce a second VPN/TUN, second cellular owner, generic root shell, generic control plane, wildcard proxy exposure, whole-UID routing, default/Wi-Fi/WARP public-egress fallback, or secret leakage.

## Current milestone policy

Until #86 changes the gate, M1 still owns the same product scope:

```text
production Android lifecycle
 -> durable external client credentials
 -> bounded exact-address Mesh ingress
 -> DNS/readiness implementation
 -> TCP-only client hardening
```

The scope stays in one eventual `main` milestone merge, but implementation/review is split into bounded slice PRs targeting the M1 integration branch.
