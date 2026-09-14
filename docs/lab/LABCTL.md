# LABCTL — stateless physical-lab execution adapter

`labctl` is the repository-owned stateless execution adapter for Windows physical workflows.

It is not a build system, daemon, scheduler, artifact registry, release selector, device registry, status database, or second control plane.

## Product artifact authority

For generic LAB release-consumer operations, `labctl` still consumes an exact verified tuple:

```text
tag
source commit
APK SHA-256
signing-certificate SHA-256
        ↓
labctl release resolve
        ↓
exact GitHub Release metadata + exact named assets
        ↓
labctl release verify
        ↓
PASS verification receipt
        ↓
android install may consume only those still-identical bytes
```

`latest` is never a machine input. Android product builds never run through `labctl`.

For E3, the operator no longer copies that tuple manually. The E3 workflow resolves the exact active immutable RC and matching same-source/same-signing harness, then passes the machine-owned tuple to the existing fail-closed `labctl` verifiers.

The release signing-certificate fingerprint remains a reviewed stable trust anchor in the E3 consumer workflow. Per-RC source SHA, APK digest, ABI, harness run/artifact IDs, harness ZIP digest and test-APK digest are derived from the exact native-immutable GitHub Release and matching release run rather than copied into the workflow for each candidate.

## Native immutable release prerequisite

The repository GitHub setting `Enable release immutability` is part of the release-consumer trust contract and must be enabled before publishing an E3 candidate.

E3 accepts only release API metadata with:

```text
immutable=true
```

This is deliberately stronger than release notes or naming conventions. A release with `immutable=false` is not an E3 artifact authority even when its tag, manifest, certificate and current asset digest otherwise look correct.

GitHub native immutable releases lock published assets and the associated release tag. The setting applies only to future releases; historical mutable RCs remain historical evidence and are not silently upgraded by enabling the setting later.

## Entry point

```powershell
C:\mish-lab\tools\powershell-7.6.6\pwsh.exe -NoLogo -NoProfile -NonInteractive -File .\lab\windows\labctl.ps1 <area> <action> ...
```

Current bounded surface:

```text
host inspect
release resolve
release verify
android inspect
android install
evidence collect
cloudflare prove
e3 verify
e3 ready
e3 execute
e3 accept
e4 plan
e4 finalize
```

`android install` requires a PASS `mish.lab.release-verification/v1` receipt, re-checks the exact authorized tuple, and re-hashes the APK immediately before invoking ADB. Changing the APK after verification therefore fails before installation.

`evidence collect` is the managed-LAB readiness evidence projection. It emits `mish.lab.evidence/v1` through an explicit allowlist; arbitrary receipt fields, local paths, device identifiers, public-IP literals and secret-shaped data are not copied into durable evidence.

## E3 identity projection

The E3 workflow has one hosted resolver job before the self-hosted Windows job. The hosted resolver proves:

```text
exact active RC tag syntax
 -> exact Git tag commit
 -> commit is in accepted main lineage
 -> published non-draft RC prerelease
 -> GitHub reports immutable=true
 -> canonical release asset set
 -> GitHub APK SHA-256
 -> downloaded APK SHA-256
 -> mish.android-release/v1 manifest verification
 -> reviewed release-signing certificate trust anchor
 -> exactly one successful machine-owned Android Release Candidate run
 -> exactly one named E3 harness artifact for that run/tag/source
 -> non-expired artifact + canonical artifact digest
 -> harness manifest/product/test byte verification
 -> test APK SHA-256
```

Those facts become job outputs only for the current workflow run. They are not a new mutable release registry, status database, or second source of truth.

The Windows physical job then independently repeats the existing consumer checks using those machine-owned values:

```text
labctl release resolve
labctl release verify
e3 verify
```

So simplification removes manual identity transcription, not verification depth.

## E3 bounded commands

The E3 surface changes execution/supply/evidence mechanics only; Issue #10 remains the semantic owner of the physical Cellular Egress positive/negative/recovery contract.

```text
e3 verify
  = verify exact harness run/artifact/ZIP/manifest/test-APK identity
    against an already verified exact product RC and machine-projected digests

e3 ready
  = create the pre-device domain readiness receipt after an explicit
    zero-ADB observation; this receipt is not E3 acceptance

e3 execute
  = PHONE-ON adapter for the continuous Issue #10 lifecycle
    positive -> cellular loss -> recovery using exact accepted bytes

e3 accept
  = after a successful physical e3 execute result, revalidate the exact
    release/harness bytes and project mish.lab.e3-acceptance/v1 on the
    accepted Windows x64 / protected-main boundary
```

These are bounded stateless commands. They do not create a daemon, scheduler, status database, second E3 workflow, second CURRENT pointer, release registry, routing owner, or parallel semantic owner.

`e3 execute` is evidence machinery, not the Cellular Egress owner. It exercises the exact PRODUCT-owned adapter and observes owner-derived state; LAB/ADB root may perform only the explicitly authorized mobile-data loss/recovery mutation. ADB root must not substitute for PRODUCT runtime root authority.

`e3 accept` is deliberately separate from readiness. It requires `result=PASS`, `scenario=full-root-toggle`, `e3_pass=true` from the exact execution result plus matching still-identical PRODUCT and test APK bytes. It emits a sanitized receipt containing only GitHub execution identity, exact release identity and exact harness identity. The physical workflow uploads that receipt as `e3-acceptance-<RC>` only after the acceptance projection succeeds.

`NO_EVIDENCE_ESCALATION` is mandatory: hosted RC resolution, `e3 verify`, hosted contract CI, `e3 ready` with `device_count=0`, or LAB-only root-policy canaries cannot claim E3 PASS.

## Physical execution gate

The E3 workflow may run hosted contract validation on pull requests and `push` to `main`, but its resolver and self-hosted physical job are admitted only by a manual `workflow_dispatch` on protected `main`:

```text
github.event_name == workflow_dispatch
AND github.ref == refs/heads/main
AND github.ref_protected == true
```

A PR or merge therefore validates the contract automatically but must never start the Windows physical LAB.

The accepted physical runner remains:

```text
[self-hosted, windows, x64, mobile-proxy-mish-lab]
```

PowerShell is invoked only through:

```text
C:\mish-lab\tools\powershell-7.6.6\pwsh.exe
```

from `shell: cmd` physical steps. Physical commands use repository-owned `labctl.ps1` through `pwsh -File`; inline arbitrary `pwsh -Command` is not part of the accepted boundary.

The physical runner receives no Android release signing secret and performs no Gradle/Cargo/Rust/NDK Android build.

## E3 operator protocol

From accepted protected `main`:

```text
Actions -> E3 Physical Cellular -> Run workflow
```

The operator does **not** enter or copy source commit, APK digest, signing certificate, harness run/artifact IDs, harness ZIP digest, or test APK digest. Those are resolved and verified from the exact native-immutable active RC identity.

A pre-device proof, when used by the contract, requires zero ADB devices, installs nothing, and may only produce:

```text
PHONE-ON READY
E3_PASS=NO
NO_EVIDENCE_ESCALATION=PASS
```

The full physical acceptance path uses an exact RC/harness pair implementing the root-policy lifecycle:

```text
request direct CELLULAR + INTERNET + NOT_VPN
 -> owner ADMITTED with fresh generation
 -> PRODUCT root policy reconciled for intended proxy egress
 -> current direct-cellular route validated behind fail-closed guard
 -> cellular-owned DNS/public egress succeeds
 -> bounded LAB mobile-data loss mutation
 -> direct cellular lost / owner NOT_ADMITTED / old generation unusable
 -> target egress fails closed; no Wi-Fi/default/WARP fallback
 -> bounded LAB mobile-data restore
 -> same PRODUCT lifecycle reacquires direct cellular
 -> fresh generation + fresh policy reconciliation
 -> cellular-owned public egress succeeds again
 -> typed mish.lab.e3-acceptance/v1 projected and uploaded
```

Wi-Fi is not an E3 correctness prerequisite and cannot satisfy Cellular Egress. Cloudflare/VPN-derived networks cannot satisfy the `NOT_VPN` owner policy. Cloudflare One Agent remains connected as the target-topology coexistence fixture, but E3 does not claim Mesh end-to-end acceptance.

Unsupported/unvalidated IPv6 must remain fail closed. Whole-PRODUCT-UID routing and any dedicated egress helper remain prohibited assumptions until separately justified by physical privilege/lifecycle/isolation evidence.

## E4 bounded commands

E4 is formalized as a stateless two-phase acceptance coordinator. The detailed contract is in `docs/lab/E4_RUNNER.md` and `docs/testing/E4_FULL_STACK.md`.

```text
e4 plan
  = bind a non-PASS E4 session to a PASS exact release-verification receipt,
    a PASS mish.lab.e3-acceptance/v1 receipt for the exact same PRODUCT bytes,
    still-identical PRODUCT APK bytes, the pinned external-client fixture,
    and the canonical mandatory E4 scenario matrix

e4 finalize
  = on the accepted Windows x64/protected-main boundary, revalidate the
    session-bound PRODUCT bytes, E3 acceptance digest, fixture and complete
    physical scenario observations, then emit sanitized PASS/FAIL/BLOCKED evidence
```

`e4 plan` always emits `e4_pass=false` and `NO_EVIDENCE_ESCALATION`. It rejects readiness-only evidence, a different E3 RC, or a changed E3 acceptance receipt. Hosted E4 contract tests cannot claim physical acceptance.

`e4 finalize` has machine-distinct outcomes:

```text
PASS    -> exit 0 / e4_pass=true
FAIL    -> exit 2 / e4_pass=false
BLOCKED -> exit 3 / e4_pass=false
```

PASS/BLOCKED durable E4 evidence includes the E3 acceptance SHA-256 and bounded E3 execution/test identity without persisting the local E3 receipt path. This makes the same-RC E3 -> E4 chain auditable without copying sensitive physical data.

A missing required external runtime is not silently converted into PASS. Every canonical M1 scenario is mandatory, including literal five-minute background idle, ten-session post-idle load, Force Stop semantics, normal-stop cleanup, fresh root authorization, One Agent/One Client recovery, UDP/IPv6 fail-closed checks and the pinned real-client fixtures.

The E4 coordinator is evidence machinery only. It does not build PRODUCT, mutate Cloudflare/provider state, edit Magisk policy, create routing truth, or own runtime readiness. Merging the coordinator does not execute E4 and does not change `PROXY_ON_PHONE_WORKING`.

## Trust and privacy rules

The E3/E4 simplification preserves all existing trust boundaries:

```text
NO untrusted PR execution on self-hosted runner
NO arbitrary-ref physical execution
NO release signing key on Windows LAB
NO Android rebuild on Windows LAB
NO latest/ambiguous RC selection
NO mutable GitHub Release as physical byte authority
NO human-copied per-RC digest/artifact tuple as acceptance authority
NO readiness -> E3 PASS escalation
NO E4 without exact typed E3 PASS for the same PRODUCT bytes
NO carrier public-IP persistence
NO device/SIM/network identifiers in durable public evidence
NO arbitrary physical observation fields copied into E4 durable evidence
```

A mutable, missing, ambiguous, expired, mismatched, non-canonical or stale-mechanism release/harness identity fails closed before physical execution. E4 additionally refuses missing/duplicate/unknown scenarios, stale session bytes, changed E3 acceptance bytes and untrusted finalization refs.
