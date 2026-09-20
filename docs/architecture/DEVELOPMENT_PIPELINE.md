# Development CI and DEVICE-1 candidate contract

This document is the stable development-delivery contract. Protected `main` is the latest accepted PRODUCT + CONTROL source. Live stage/checkpoint state belongs to Issue #135. Ordered PRODUCT direction belongs to `PRODUCT_ROADMAP.md`. Executable workflows are the mechanical authority if prose and YAML disagree.

`RELEASE.md` now records the same exact-artifact identity rule. There is no separate RC/release acceptance pipeline.

## Supported PRODUCT floor

```text
Android 11 / API 30
armeabi-v7a
```

Canonical build authority remains the Android/Rust build graph. Android 23 and Android 26 are not supported PRODUCT compatibility floors. Do not add lower-API compatibility shims unless a new accepted PRODUCT requirement explicitly reopens support below API 30.

## Protected-main PR validation + PRODUCT candidate

`.github/workflows/integration-android-preflight.yml` is the single protected-main PR validation workflow and the exact-head hosted candidate producer for PRODUCT-changing PRs. The obsolete separate `.github/workflows/ci.yml` workflow does not exist: cheap CONTROL guards, Rust quality and Android candidate production form one ordered pipeline.

Current contract:

```text
PR to main opened / synchronized / reopened / ready-for-review
 -> Control Guards ----------------------┐
 -> Device Cycle Contracts --------------┤
                                         ├-> Rust Workspace -----------┐
                                         └-> Android Build/Test -------┤
                                                                      └-> Android Compose Shell
                                                                          final aggregate gate
                                                                          -> publish canonical exact-head candidate
```

For PRODUCT/build changes, Rust Workspace and Android Build/Test run in parallel after the shared lightweight guards. They use distinct cache namespaces, so concurrent hosted work never races on one mutable cache key. Android Build/Test may publish a one-day, non-canonical staging artifact only; Device Cycle never resolves that name. The required `Android Compose Shell` context is the final aggregate gate and publishes the canonical `device-candidate-pr-<PR>-<SHA>` artifact only after both Rust and Android branches succeed.

The canonical candidate artifact is therefore produced only after the complete configured gate succeeds.

A successful hosted build is a prerequisite only. No successful build, merge to main, label, or completed workflow starts DEVICE-1.

## Exact candidate identity

Ready candidate artifact naming:

```text
device-candidate-pr-<PR>-<40-hex PRODUCT_SHA>
```

The artifact contains the debug PRODUCT APK, AndroidTest APK and `candidate.json` with exact source/base identity, application id, target ABI and APK digests.

Expired, superseded or mismatched artifacts fail closed; never silently substitute bytes from another commit.

### Canonical Windows candidate version store

The self-hosted Windows LAB uses one durable location for downloaded/installed development candidate versions:

```text
C:\mish-lab\runner\.state\device-candidate\versions\<SOURCE_SHA>\<ARTIFACT_ID>\
  provenance.json
  hosted\
    candidate.json
    mobile-proxy-mish-debug.apk
    mobile-proxy-mish-debug-androidTest.apk
  signed\
    mobile-proxy-mish-debug-lab-signed.apk
    mobile-proxy-mish-debug-androidTest-lab-signed.apk
  receipts\
    install-v2.json
    installed-verification-v2.json
```

There is deliberately **no** `latest`, `current`, mutable pointer or source-SHA-only alias. A hosted workflow rerun may produce another artifact for the same source SHA, so the durable version coordinate is `SOURCE_SHA + ARTIFACT_ID`; `provenance.json` also records hosted run id, artifact name/digest and hosted APK digests.

`$RUNNER_TEMP` is download/pull scratch space only. It is never a candidate-version authority and is safe to disappear after the job.

The local store is a durable provenance/cache surface, **not a second candidate resolver**. A normal `full` or `install_only` Device Cycle must still resolve an eligible completed PR Validation + PRODUCT Candidate run and exact GitHub artifact id/digest first, download that artifact, validate its `candidate.json`, then materialize the exact bytes into the canonical store. An expired/missing GitHub artifact must fail closed; the workflow must never silently install an older local copy.

Candidate identity has three distinct layers:

```text
hosted source candidate
  = exact APK bytes emitted by PR Validation + PRODUCT Candidate
  = candidate.json hosted_product_apk_sha256

LAB-signed install candidate
  = those exact hosted payload bytes signed by the persistent LAB signing identity
  = install-v2.json lab_signed_product_apk_sha256

installed base.apk
  = bytes pulled back from DEVICE-1 after adb install
  = installed-verification-v2.json installed_apk_sha256
```

The hosted APK SHA-256 and installed APK SHA-256 are normally different because LAB signing changes APK bytes. Exact installation proof is therefore **not** `hosted SHA == installed SHA`. It is the verified lineage:

```text
resolved GitHub artifact id/digest
 -> hosted candidate.json + hosted APK digest verified
 -> LAB signing produces recorded lab_signed_product_apk_sha256 + signing certificate
 -> adb install
 -> pulled installed base.apk SHA == lab_signed_product_apk_sha256
 -> pulled installed certificate == recorded LAB signing certificate
```

Receipt wording must say `installed_matches_lab_signed_candidate`, never an ambiguous `installed_matches_accepted_candidate`.

## Protected-main Device Cycle

`.github/workflows/device-cycle.yml` owns development physical execution.

The canonical engineering loop is intentionally explicit:

```text
diagnostic -> analysis -> decision -> code -> completed build -> explicit cycle request -> install -> verify install -> launch -> diagnostic -> analysis
```

Diagnostics never chooses a repair. No automatic targeted probe is allowed. Analysis chooses any follow-up action after the previous run has stopped.

One explicit request produces one GitHub Actions Device Cycle run. There is no automatic start from build completion, PR merge, main merge, label or artifact publication.

Device Cycle is started only by an explicit human/operator request against the current protected `main`. There is no PR/build/merge/artifact auto-start. Two equivalent manual entry points are supported:

```text
GitHub Actions workflow_dispatch:
  pr_number   = <PR that owns the immutable candidate>
  product_sha = <exact 40-hex PRODUCT_SHA>
  mode        = full | install_only | diagnose_only | probe_only
  probe       = none | capacity_resources | recovery_lifecycle | dns_lifetime_live | u5_rotation | loopback_connect

Repository-owner operator comment:
  /mish-cycle <PR> <PRODUCT_SHA> <mode> <probe>
```

The comment form is accepted only from repository owner `iamaman11` and is an explicit operator command, not an automatic reaction to build or merge state. Both entry points normalize into the same resolver and exact provenance checks.

`probe_only` requires `probe=loopback_connect`.

`full` accepts `probe=none` or one explicit probe: `capacity_resources`, `recovery_lifecycle`, `dns_lifetime_live`, or `u5_rotation`. None is selected automatically. `install_only` and `diagnose_only` require `probe=none`.

`capacity_resources` and `recovery_lifecycle` are acceptance probes when their required baseline and exact-candidate evidence are complete. `dns_lifetime_live` is deliberately **measurement-only**: it collects one bounded same-process native DNS lifetime observation across a Cellular loss/recovery generation change. A green DNS measurement does not independently accept the exact PRODUCT candidate; its `exact_candidate_acceptance` remains `NOT_EVALUATED`.

The DNS lifetime observation reuses the accepted external-proxy credential provisioning and ADB-forward seams, sends bounded authenticated proxy-domain requests through the existing PRODUCT HTTP CONNECT listener, requests exactly one bounded `cmd phone data disable` / `enable` transition, and proves actual loss/recovery from canonical owner snapshots. It requires PRODUCT PID continuity and a fresh native DNS owner sequence after recovery. It records occupancy/currentness/stale/deadline facts and then stops for analysis. It does not invoke androidTest, mutate PRODUCT routes/iptables, mutate Cloudflare, add a DNS executor/pool/cancellation owner, or turn measurement into a repair decision. Best-effort mobile-data restore and ADB-forward cleanup are mandatory LAB hygiene.

`u5_rotation` is the final U5 acceptance probe for the PRODUCT-owned rotation. ADB only launches debug-only zero-input PRODUCT trigger Activities and performs read-only observation. The PRODUCT itself calls the Rust-owned `startPublicIpRotation()` operation; LAB never issues airplane enable/disable, root, route or iptables mutation. The probe executes three bounded normal rotations plus one normal runtime-stop-after-observed-ON restore case, records owner generations and the required rotation timings, proves fail-closed behavior during accepted Cellular loss, compares credential version/material in memory without persisting secrets, verifies `raw_ip_persisted=false`, and records owner-backed rotation task quiescence plus process/thread/FD/session evidence before and after. Normal rotations must not replace the runtime generation or persistent root-session generation; the separate restore-case may restart the runtime only after those invariants are proven. CHANGED and UNCHANGED are both valid normal terminal outcomes. Any PRODUCT-classified rotation failure rejects the exact candidate; a LAB collection failure leaves PRODUCT acceptance unevaluated.

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
 -> explicit workflow_dispatch or owner /mish-cycle command from protected main after analysis
 -> verify PR/base/source identity
 -> verify accepted producer policy
 -> verify hosted run/artifact/digest provenance
 -> checkout exact CONTROL_SHA
 -> verify pinned PowerShell/runtime + DEVICE-1 prerequisites
 -> download exact hosted artifact into temporary staging
 -> materialize exact bytes under C:\mish-lab\runner\.state\device-candidate\versions\<SOURCE_SHA>\<ARTIFACT_ID>
 -> sign the hosted payload with the persistent LAB signing identity
 -> adb install -r the recorded LAB-signed candidate
 -> read back installed base.apk
 -> installed base.apk SHA-256 == lab_signed_product_apk_sha256
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

For `recovery_lifecycle`, the baseline process-to-instrumentation boundary is explicit: after the PASS baseline snapshot, LAB performs a non-root `am force-stop` of the PRODUCT package and proves the old package PID absent before starting the exact androidTest instrumentation. This prevents overlapping process generations from concurrently reconciling or cleaning the same PRODUCT-owned kernel policy. LAB still does not mutate RPDB/iptables or substitute its own root-policy actions.

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

Automatic airplane recovery is not part of the baseline cycle. Baseline functionality is established first. Cellular-loss/airplane/recovery acceptance is run only as the separately authorized `u5_rotation` full probe when the roadmap requires that physical fact.

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

Development device candidates are the canonical Android physical-acceptance bytes for their exact source head. They are never promoted through an RC lineage; any future distribution packaging is a separate later concern and cannot replace Device Cycle evidence.

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
