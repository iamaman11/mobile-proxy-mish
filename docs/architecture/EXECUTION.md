# Development execution and integration policy

This document defines stable execution policy. Protected `main` is the latest accepted PRODUCT + CONTROL source. Live stage status belongs only to Issue #135. Ordered product direction belongs only to `PRODUCT_ROADMAP.md`.

## Authority model

```text
protected main
  -> latest accepted PRODUCT implementation
  -> latest accepted CONTROL/workflow/LAB implementation
  -> canonical architecture/process documentation

Issue #135
  -> CURRENT_STAGE
  -> OPEN_IMPLEMENTATION_PR
  -> immutable evidence ids

open implementation PR
  -> temporary candidate change under review
```

An open PR head is not a second accepted PRODUCT source. Once its required evidence passes, merge it to `main` promptly so accepted implementation and accepted process stay together.

## Single-pass roadmap rule

Development proceeds linearly through `PRODUCT_ROADMAP.md`. Exactly one roadmap stage is current.

Within a stage:

```text
fresh exact main baseline
 -> complete independent hosted/code work
 -> exact-head hosted gate when configured/required
 -> physical fact only when source/hosted evidence cannot establish it
 -> record immutable evidence in #135
 -> fix only surfaced defects on the same stage
 -> merge accepted slice to main
 -> advance #135 only when stage exit criteria are complete
```

A failed gate does not create a new roadmap stage.

## Work units

Keep these distinct:

```text
commit batch != slice PR != roadmap-stage completion
```

A normal slice branch starts from fresh protected `main`.

Default slice shape:

- one natural owner;
- at most one necessary platform/vendor/composition adapter;
- direct tests for that owner/adapter boundary.

Open a slice PR against `main` when the change is coherent enough to review. Use another base only for an explicitly documented short-lived exceptional dependency; do not create a long-lived accepted integration branch.

## Protected-main boundary

`main` is the accepted integration boundary, not a scratch branch and not merely a progress ledger.

Accepted PRODUCT/control changes land on `main`. Do not keep already accepted PRODUCT state indefinitely on a parallel branch just to preserve process history; Git and PR history already provide that history.

## CI law

Executable workflow configuration is the mechanical authority. Prose follows YAML, never the reverse.

`Integration Android Preflight` is the exact-head hosted candidate producer for PRODUCT-changing PRs to `main`. Read `.github/workflows/integration-android-preflight.yml` for exact trigger conditions and steps.

General law:

```text
coherent exact PR head
 -> configured complete hosted gate
 -> first failing gate is current hosted diagnosis
 -> smallest owner-aligned correction
 -> new exact SHA
 -> full required evidence re-established for that SHA
```

Do not carry a PASS across a changed SHA.

## Physical development loop

A successful build is never a phone-mutation trigger.

When #135 requires a physical fact:

```text
open ready PR to main
 -> exact hosted candidate already exists
 -> analysis decides one explicit Device Cycle action
 -> /mish-cycle command against exact PRODUCT SHA
 -> protected-main CONTROL_SHA resolves/verifies provenance
 -> physical runner consumes exact artifact; no local rebuild
 -> bounded install/launch/diagnostic/probe as requested
 -> immutable typed evidence
 -> STOP_FOR_ANALYSIS
 -> accepted change merges to main
```

The current supported modes/probes are defined by `.github/workflows/device-cycle.yml` and `DEVELOPMENT_PIPELINE.md`.

No workflow automatically chooses a repair, starts a follow-up probe, rotates credentials, changes PRODUCT policy or starts a second cycle.

## PRODUCT / CONTROL / DEVICE provenance

For a pre-merge physical candidate run, keep separate:

```text
PRODUCT_SHA
CONTROL_SHA
HOSTED_RUN_ID when an artifact is consumed
DEVICE_CYCLE_RUN_ID or equivalent immutable physical evidence id
```

This split is evidence provenance only. After acceptance and merge, the accepted PRODUCT and CONTROL source are both protected `main`.

Do not mix a stale APK, different control scripts, prior device state or local rebuild into one acceptance claim.

## Diagnostic/local-agent escalation

Use a local agent only when the exact physical fact cannot be established correctly from source, hosted CI or current Device Cycle capabilities.

```text
material ambiguity
 -> exact missing fact
 -> smallest bounded read-only diagnostic by default
 -> sanitized evidence
 -> implementation decision
```

The local agent does not own architecture or current product state. Record material conclusions back to #135 or a natural-owner/evidence contract.

## Evidence boundary

Development exact-head debug candidates may establish stage-specific physical facts when #135 records them with exact provenance. They are not formal release identity.

Formal RC/release acceptance and promotion continue to follow `RELEASE.md` and build-once/hash/sign/attest/test/promote semantics.

## Stop rule

If the accepted requirement is already met, NO CHANGE is preferred.

Do not add retries, larger timeouts, compatibility code, a new framework, second owner, root daemon/helper, status DB or fallback path until exact evidence demonstrates a product requirement for it.
