# Development execution and integration policy

This document defines stable execution policy. Live stage status belongs only to Issue #135. Ordered product direction belongs only to `PRODUCT_ROADMAP.md`.

## Authority model

```text
protected main
  -> stable process/control/canonical docs boundary

Issue #135
  -> CURRENT_STAGE
  -> WORKING_LINEAGE
  -> ACCEPTED_INTEGRATION_HEAD
  -> OPEN_IMPLEMENTATION_PR
  -> immutable evidence ids

working lineage / current slice PR
  -> current PRODUCT implementation while the stage is active
```

`main` may intentionally lag the current PRODUCT implementation during an active stage. Do not infer PRODUCT composition from `main` when #135 points to a newer accepted integration head.

## Single-pass roadmap rule

Development proceeds linearly through the current `PRODUCT_ROADMAP.md` stage order. Exactly one roadmap stage is current.

Within a stage:

```text
fresh exact baseline
 -> complete independent hosted/code work
 -> exact-head hosted gate when configured/required
 -> physical fact only when source/hosted evidence cannot establish it
 -> record immutable evidence in #135
 -> fix only surfaced defects on the same stage
 -> advance #135 only when stage exit criteria are complete
```

A failed gate does not create a new roadmap stage.

## Work units

Keep these distinct:

```text
commit batch != slice PR != milestone/main boundary
```

A slice branch starts from the exact current working/integration head in #135.

Default slice shape:

- one natural owner;
- at most one necessary platform/vendor/composition adapter;
- direct tests for that owner/adapter boundary.

Open a slice PR when the change is coherent enough to review. Its base is the current integration branch from #135 unless #135 explicitly records another boundary.

After review, merge the slice into the integration lineage. Updating the integration lineage does not automatically justify a `main` merge, physical run or release build.

## Protected-main boundary

`main` is not a progress ledger. Merge PRODUCT implementation to `main` only at a coherent milestone/evidence boundary defined by the active process.

A docs/control-only PR may update protected `main` earlier when its purpose is to keep source-of-truth, workflow or evidence mechanics accurate. Such a merge must not claim that newer PRODUCT code on the working lineage has already landed on `main`.

## CI law

Executable workflow configuration is the mechanical authority. Prose must follow YAML, never the reverse.

For the current Android/Rust development line, `Integration Android Preflight` is the exact-head hosted candidate producer. Read `.github/workflows/integration-android-preflight.yml` for exact trigger conditions and steps.

General law:

```text
coherent exact PRODUCT head
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
exact hosted candidate already exists
 -> analysis decides one explicit Device Cycle action
 -> /mish-cycle command against exact PRODUCT SHA
 -> protected-main CONTROL_SHA resolves/verifies provenance
 -> physical runner consumes exact artifact; no local rebuild
 -> bounded install/launch/diagnostic/probe as requested
 -> immutable typed evidence
 -> STOP_FOR_ANALYSIS
```

The current supported modes/probes are defined by `.github/workflows/device-cycle.yml` and `DEVELOPMENT_PIPELINE.md`.

No workflow automatically chooses a repair, starts a follow-up probe, rotates credentials, changes PRODUCT policy or starts a second cycle.

## PRODUCT / CONTROL / DEVICE provenance

Every physical conclusion must keep separate:

```text
PRODUCT_SHA
CONTROL_SHA
HOSTED_RUN_ID when an artifact is consumed
DEVICE_CYCLE_RUN_ID or equivalent immutable physical evidence id
```

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

The local agent does not own architecture or current product state. Record relevant conclusions back to #135 or a natural-owner/evidence contract.

## Evidence boundary

Development exact-head debug candidates may establish stage-specific physical facts when #135 records them with exact provenance. They are not formal release identity.

Formal RC/release acceptance and promotion continue to follow `RELEASE.md` and build-once/hash/sign/attest/test/promote semantics.

## Stop rule

If the accepted requirement is already met, NO CHANGE is preferred.

Do not add retries, larger timeouts, compatibility code, a new framework, second owner, root daemon/helper, status DB or fallback path until exact evidence demonstrates a product requirement for it.
