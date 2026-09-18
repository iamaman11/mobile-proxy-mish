# Development CI and DEVICE-1 candidate contract

This document is the stable development-delivery contract. Protected `main` is the latest accepted PRODUCT + CONTROL source. Live stage/checkpoint state belongs to Issue #135. Ordered PRODUCT direction belongs to `PRODUCT_ROADMAP.md`. Executable workflows are the mechanical authority if prose and YAML disagree.

It does not replace `RELEASE.md` for formal RC/release promotion.

## Supported PRODUCT floor

```text
Android 11 / API 30
armeabi-v7a
```

Canonical build authority remains the Android/Rust build graph. Android 23 and Android 26 are not supported PRODUCT compatibility floors. Do not add lower-API compatibility shims unless a new accepted PRODUCT requirement explicitly reopens support below API 30.

## Integration Android Preflight

`.github/workflows/integration-android-preflight.yml` is the exact-head hosted candidate producer for PRODUCT-changing PRs targeting protected `main`.

Current contract:

```text
PR to main opened / synchronized / reopened / ready-for-review
 -> checkout exact PR head
 -> Kotlin compile + lint
 -> when PR is ready/non-draft:
      Rust fmt
      Rust clippy -D warnings
      Rust workspace tests --locked
      Android Rust/NDK setup
      Android/Kotlin unit tests
      assembleDebug
      assembleDebugAndroidTest
      exact PRODUCT candidate verification
      publish exact-head device candidate artifact
```

The candidate artifact is produced only after the complete configured gate succeeds.

A successful hosted build is a prerequisite only. No successful build, merge to main, label, or completed workflow starts DEVICE-1.

## Exact candidate identity

Ready candidate artifact naming:

```text
device-candidate-pr-<PR>-<40-hex PRODUCT_SHA>
```

The artifact contains the debug PRODUCT APK, AndroidTest APK and `candidate.json` with exact source/base identity, application id, target ABI and APK digests.

Expired, superseded or mismatched artifacts fail closed; never silently substitute bytes from another commit.

## Protected-main Device Cycle

`.github/workflows/device-cycle.yml` owns development physical execution.

The canonical engineering loop is intentionally explicit:

```text
diagnostic -> analysis -> decision -> code -> completed build -> explicit cycle request -> install -> verify install -> launch -> diagnostic -> analysis
```

Diagnostics never chooses a repair. No automatic targeted probe is allowed. Analysis chooses any follow-up action after the previous run has stopped.

One explicit request produces one GitHub Actions Device Cycle run. There is no automatic start from build completion, PR merge, main merge, label or artifact publication.

Current accepted command forms are defined by the workflow. At this policy revision they are:

```text
/mish-cycle full <PRODUCT_SHA>
/mish-cycle full <PRODUCT_SHA> capacity_resources
/mish-cycle full <PRODUCT_SHA> recovery_lifecycle
/mish-cycle full <PRODUCT_SHA> dns_lifetime_live
/mish-cycle install_only <PRODUCT_SHA>
/mish-cycle diagnose_only <PRODUCT_SHA>
/mish-cycle probe_only <PRODUCT_SHA> loopback_connect
```

`probe_only` supports only the current-function `loopback_connect` probe unless the executable workflow is deliberately changed and this document is updated with it.

`full` accepts one optional, explicit probe: `capacity_resources`, `recovery_lifecycle`, or `dns_lifetime_live`. None is selected automatically. `install_only` and `diagnose_only` accept no probe argument.

`capacity_resources` and `recovery_lifecycle` are acceptance probes when their required baseline and exact-candidate evidence are complete. `dns_lifetime_live` is deliberately **measurement-only**: it collects one bounded same-process native DNS lifetime observation across a Cellular loss/recovery generation change. A green DNS measurement does not independently accept the exact PRODUCT candidate; its `exact_candidate_acceptance` remains `NOT_EVALUATED`.

The DNS lifetime observation reuses the accepted external-proxy credential provisioning and ADB-forward seams, sends bounded authenticated proxy-domain requests through the existing PRODUCT HTTP CONNECT listener, requests exactly one bounded `cmd phone data disable` / `enable` transition, and proves actual loss/recovery from canonical owner snapshots. It requires PRODUCT PID continuity and a fresh native DNS owner sequence after recovery. It records occupancy/currentness/stale/deadline facts and then stops for analysis. It does not invoke androidTest, mutate PRODUCT routes/iptables, mutate Cloudflare, add a DNS executor/pool/cancellation owner, or turn measurement into a repair decision. Best-effort mobile-data restore and ADB-forward cleanup are mandatory LAB hygiene.

## PRODUCT_SHA and CONTROL_SHA

Protected `main` is the accepted source for both PRODUCT and CONTROL. The two-SHA form exists only as physical evidence provenance:

```text
PRODUCT_SHA = exact candidate source being physically exercised
CONTROL_SHA = exact protected-main workflow/scripts executing that physical cycle
```

That split does not create two accepted sources. When a candidate is accepted and merged, protected `main` again contains the accepted PRODUCT and CONTROL together.

For `full` / `install_only`:

- an open candidate must be a ready PR to `main`;
- a merged candidate may be reused only when the resolver proves its canonical PRODUCT input tree is exactly identical to current protected `main`;
- the exact hosted candidate producer must already have completed successfully;
- the producer workflow blob at PRODUCT_SHA must match the protected-main producer workflow blob required by the Device Cycle resolver;
- any mismatch fails closed before installation.

A merged candidate is never reused merely to reconstruct accepted state. Reuse is allowed only for a new explicit physical need when PRODUCT identity is mechanically unchanged by later control-only commits.

## Physical runner contract

The Windows LAB is a consumer, not a builder.

Normal path:

```text
successful exact hosted artifact already exists
 -> explicit /mish-cycle request after analysis
 -> verify PR/base/source identity
 -> verify accepted producer policy
 -> verify hosted run/artifact/digest provenance
 -> checkout exact CONTROL_SHA
 -> verify pinned PowerShell/runtime + DEVICE-1 prerequisites
 -> consume exact candidate when the mode installs
 -> adb install -r when mode requests installation
 -> read back installed base.apk
 -> installed base.apk SHA-256 == exact signed candidate SHA-256
 -> verify installed signing identity
 -> launch when mode requests it
 -> collect generation-consistent current-L8 diagnostics
 -> optional explicitly requested current-function/acceptance probe
 -> produce typed evidence/report
 -> STOP_FOR_ANALYSIS
```

`adb install -r = Success` is necessary but not sufficient. When installation is part of the cycle, launch/acceptance is blocked until the installed APK bytes and signing identity are verified against the exact candidate.

The runner must not silently run Gradle, Cargo, cargo-ndk, NDK compilation, UniFFI generation, local APK assembly or clean uninstall to rescue a failed candidate path.

Pinned PowerShell/tool requirements are real physical-run prerequisites and are enforced by the executable workflow/scripts.

## Modes

### `full`

Requires an already successful exact-head hosted candidate from a ready PR lineage accepted by the resolver.

```text
resolve provenance
 -> install exact candidate
 -> verify installed bytes/signing identity
 -> launch/restart app as defined by workflow
 -> canonical diagnostics
 -> optional explicitly requested acceptance probe
 -> exact-candidate acceptance classification
 -> STOP
```

With no probe argument this is the normal baseline. With `capacity_resources`, the canonical baseline must first PASS, then the same run executes one bounded capacity/resource acceptance from the Windows LAB through the real external Mesh endpoint. With `recovery_lifecycle`, the same run exercises the exact accepted recovery/E3 contract. With `dns_lifetime_live`, the baseline must PASS first and the same run collects bounded live same-process DNS lifetime evidence; that observation remains measurement-only and cannot by itself produce exact PRODUCT acceptance.

The capacity probe is deliberately correlated to the implementation owners:

```text
Windows external client -> admitted Mesh endpoint:3128
 -> mish-transport external session owner (limit 64)
 -> loopback native Proxy Serving backend
 -> Cellular Egress target connect
```

Capacity acceptance uses one monotonic application-live set that grows through `10`, `32` and `64`. At every milestone every currently held path must pass a fresh bounded HTTP request/response round-trip over its same already-established TLS connection before owner-backed `mesh.active_sessions` and `proxy.active_sessions` are accepted. At the full `64/64` precondition the probe makes exactly the required 65th overflow attempt, requires it to be rejected before Proxy Serving, then re-proves the same original 64 application-live paths and `64/64` owner counts. Finally it drains to `0/0`, records threads / FD / RSS / PSS, and performs one fresh external Mesh application round-trip after cleanup.

The routine acceptance path is deliberately linear in the configured capacity. Long lifetime soaks, repeated all-set keepalive loops while opening, and repeated overflow attempts belong to targeted diagnostics, not to the normal capacity gate. This keeps capacity acceptance bounded as the configured limit grows while preserving the decisive facts: application liveness at each milestone, natural-owner agreement, deterministic first-overflow rejection, preservation of the admitted set, cleanup, PID stability and resource evidence.

A client object, `TcpClient.Connected`, an historical CONNECT response, or an historical TLS handshake is not application-liveness evidence. An overflow connect/read/write timeout is not automatically accepted as edge rejection; ambiguous transport observations are classified as LAB failure/inconclusive and do not reject the PRODUCT candidate. A PRODUCT capacity failure is emitted only when application-live client evidence proves the required admitted set while natural-owner counts diverge, or when the required first overflow attempt reaches Proxy Serving despite the proven full-capacity precondition.

The probe does not infer capacity from `/proc/net/tcp`, does not use ADB forwarding, and does not add a LAB-owned session counter.

Resource values are measurements, not invented absolute production thresholds. Capacity, owner-count causality, PID stability and post-cleanup session drain are strict acceptance facts; resource baselines/peaks/deltas are durable evidence for later lifetime evaluation.

### `install_only`

Requires an already successful exact-head hosted candidate accepted by the resolver.

```text
resolve provenance
 -> install
 -> verify installed bytes/signing identity
 -> STOP
```

### `diagnose_only`

No candidate installation claim.

```text
use currently installed debug package
 -> explicit app launch/restart as defined by workflow
 -> canonical diagnostics
 -> STOP
```

The result cannot be promoted into exact candidate acceptance because installation identity was not established in that cycle.

### `probe_only`

No install and no app restart.

```text
run exactly one explicitly named read-only current-function probe
 -> typed evidence
 -> content-level acceptance evaluation
 -> STOP
```

A targeted JSON artifact is not success merely because it exists. The report evaluates the probe's functional acceptance fields. A green `probe_only` still does not claim exact PRODUCT acceptance because installation identity was not established in that cycle.

## Canonical diagnostics

Current APK diagnostics use `mish.diagnostics/v2` / `snapshot_v2` and observe current native facts only:

- runtime running/generation consistency;
- Cellular admission/boundary state;
- root authority/root-policy authorization;
- native Proxy Serving state/health/typed failure;
- owner-backed native Proxy Serving active-session count;
- credential state;
- Mesh admission/ingress;
- owner-backed Mesh active-session count;
- Readiness.

The active-session fields are projections of their Rust natural owners. Android and LAB do not maintain parallel capacity semaphores or counters.

Diagnostics do not own or execute repairs, root mutations, network toggles, credential rotation, install, runtime lifecycle decisions or legacy process management.

Historical Android sing-box/runtime identity is not a current PRODUCT diagnostic fact.

## Recovery sequencing

Automatic airplane recovery is not part of the baseline cycle. Baseline functionality is established first. Cellular-loss/airplane/recovery acceptance is run only as a separately authorized stage when the roadmap requires that physical fact.

## Acceptance fields

Physical reporting separates mechanical collection from PRODUCT acceptance.

```text
cycle_result
  did the requested scope meet its typed functional acceptance semantics?

exact_candidate_acceptance
  evaluated only when the exact installed candidate and every required full-mode baseline/probe fact were exercised
```

For a targeted probe, evidence presence and evidence success are separate facts. A PRODUCT-classified probe failure is not converted into LAB success because a JSON file was uploaded. LAB/control failure leaves exact PRODUCT acceptance unevaluated.

A green `probe_only` or `diagnose_only` must never be interpreted as exact candidate acceptance.

## Formal release boundary

Development debug candidates are stage/development evidence only. They are not PRODUCT release identity and cannot be promoted.

Formal promotion remains:

```text
PIN -> BUILD ONCE -> HASH -> SIGN -> ATTEST -> TEST EXACT BYTES -> PROMOTE EXACT BYTES
```

under `RELEASE.md`.

## Stable authorities

```text
accepted PRODUCT + CONTROL source       -> protected main
live execution pointer                  -> Issue #135
ordered PRODUCT plan                    -> PRODUCT_ROADMAP.md
reconstruction/authority map            -> SOURCE_OF_TRUTH.md
hosted candidate producer               -> integration-android-preflight.yml
physical development executor           -> device-cycle.yml + lab/windows scripts
architecture                            -> SYSTEM.md / DEPENDENCIES.md / OWNERSHIP.md
formal release                          -> RELEASE.md
```

Repository guards should reject drift back to automatic phone starts, local rebuilding in the normal physical path, long-lived accepted PRODUCT outside main, stale/floating control identity, automatic repair/probe decisions, legacy Android proxy assumptions, accepting `adb install` without installed-byte/signature verification, treating evidence presence as functional acceptance, or bypassing the Mesh admission owner when testing external capacity.
