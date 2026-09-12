# Executor policy

GitHub is the durable source of truth. Chat handoffs, copied status text, CI summaries and generated artifacts are not substitutes for a fresh GitHub baseline.

## Required startup baseline

Before planning or mutating:

1. read fresh protected `main`;
2. read the current cross-component execution tracker (#86);
3. read only the natural-owner issues relevant to the current change;
4. inspect the current implementation PR and its exact head;
5. distinguish current facts from historical evidence.

One fresh baseline opens one bounded mutation window. Do not re-baseline after every write performed inside that same bounded window.

## Unit of integration

The unit of merge is an **evidence milestone**, not an individual implementation task, file edit or small fix.

Several dependent code stages should remain together in one draft integration PR when they can be validated by E1/E2 evidence without requiring accepted `main`.

Do not merge to `main` merely because one internal implementation stage is complete.

Merge to `main` only when at least one of these is true:

- the coherent integration milestone is complete as far as E1/E2 can prove it;
- the next missing fact can only be obtained from a main-only LAB/provider/release path;
- a natural-owner contract explicitly requires accepted `main`;
- the change must establish a protected-main compatibility boundary before further work.

## Draft integration PR rule

Keep an implementation PR in Draft while the milestone is under construction.

Do not run expensive hosted CI after every small edit. Accumulate a coherent bounded batch first.

When several repository files must change through GitHub, prefer:

```text
prepare all edits
 -> one Git tree
 -> one commit
 -> one branch-ref update
```

instead of one remote commit per file/edit.

A push should represent a coherent reviewable batch, not an editor save point.

## CI rule

Heavy CI is deliberate evidence, not an edit loop.

While an integration PR is Draft, ordinary PR updates may perform only cheap impact/policy work; the expensive Rust/Android jobs are intentionally skipped. A deliberate `workflow_dispatch` may still run full CI on an exact draft head when a meaningful batch needs hosted validation.

Before merge, mark the PR ready for review and require complete CI PASS on the exact PR head. After any change to a previously validated ready-for-review head, exact-head CI must pass again.

## Main rule

`main` is an accepted integration/evidence boundary. Do not use `main` as a scratch integration branch.

Do not merge lifecycle, credentials, Mesh ingress, DNS/readiness or adjacent implementation work separately merely to record progress when no stronger-evidence boundary requires it.

Record intermediate progress in #86 and the draft integration PR instead.

## Development LAB rule

Development LAB consumes an exact accepted green PRODUCT `main` SHA. Never claim LAB evidence from a PR branch.

Do not create a new LAB candidate merely because one PR or internal stage completed.

Run development LAB only when #86 identifies a physical fact that cannot be legitimately established by E1/E2 evidence and that fact is needed for the next implementation decision or acceptance gate.

Batch all code work that does not require that physical fact before crossing the `main -> LAB` boundary.

## Physical correction loop

When LAB reveals a physical defect, use:

```text
typed physical finding
 -> bounded correction batch
 -> deliberate exact-head CI
 -> one merge
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

Until #86 changes the gate, accumulate all E1/E2-completable work for the next physical checkpoint in the same draft integration PR.

The expected next `main -> LAB` boundary is after the coherent lifecycle + durable credentials + bounded Mesh ingress + DNS/readiness + TCP-hardening integration milestone, not after each component individually.
