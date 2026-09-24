# Readiness and acceptance

Runtime readiness is one pure derived projection over fresh owner observations:

```text
READY
NOT_READY
DEGRADED
UNKNOWN
```

Lifecycle is orthogonal. Missing or stale required observations become `UNKNOWN`; `UNKNOWN` never counts as success.

Protected `main` is the latest accepted PRODUCT + CONTROL source.

## Evidence levels

```text
E1  code / deterministic hosted CI
E2  Android emulator / bounded platform integration
E3  physical rooted Android + real carrier / real device topology
E4  Windows -> Cloudflare Mesh -> Android -> cellular -> external client full path
```

`NO_EVIDENCE_ESCALATION`: weaker evidence cannot close a stronger claim.

## Development physical evidence and future distribution evidence

The current development/physical path and any future external-distribution path must not be conflated.

### Stage-specific development DEVICE-1 evidence

An exact-head debug candidate produced by `Integration Android Preflight` may be consumed by the explicit protected-main `Device Cycle` workflow while its ready PR to `main` is still open when Issue #135 says the current stage requires that physical fact.

Such evidence is valid for the exact stage claim only when it records explicit provenance, including:

```text
PRODUCT_SHA
CONTROL_SHA
hosted candidate/run identity when applicable
physical run/evidence id
installed-byte/signature verification when installation is part of the claim
```

A `full` Device Cycle may establish exact-candidate stage acceptance facts for that open PR. `diagnose_only` and `probe_only` evidence are observations for analysis and do not prove that a requested PRODUCT candidate was installed/accepted.

Once accepted, the candidate change merges to `main`; the PRODUCT_SHA/CONTROL_SHA split remains evidence provenance, not a second accepted source.

Development debug evidence is not an external-distribution identity and cannot be relabeled as one.

### External distribution acceptance — future only

There is no current RC/prerelease/promotion path. U8 closes on the exact hosted-candidate -> LAB-sign
-> installed-byte -> Device Cycle lineage defined by `RELEASE.md`.

If a future external/store distribution requirement appears, it must define one exact immutable
distribution identity and preserve the existing source/build/physical authorities. A debug candidate
cannot be silently relabeled as a production distribution artifact, and a parallel RC hierarchy must
not be introduced without a demonstrated requirement.

For U8 support/provenance reconstruction, use existing immutable GitHub identities only:
`ACCEPTED_MAIN_SHA`, exact `PRODUCT_SHA`/`CONTROL_SHA` when they intentionally differ during
candidate evidence, hosted run/artifact identity, Device Cycle run, installed byte/signing proof when
applicable, and the typed result/classification. No new physical run is required merely to assemble
that support packet.

## Current-product physical rules

Physical acceptance observes only current PRODUCT owners and current external fixtures:

- runtime generation/lifecycle;
- Cellular admission/currentness and exact-network egress;
- root authority/root-policy authorization;
- native Rust Proxy Serving;
- credentials;
- Mesh transport/ingress;
- readiness;
- functional protocol/auth/relay behavior;
- bounded resource/timing evidence when required by the active roadmap stage.

Historical Android sing-box processes/files are not current-product health facts. They are LAB residue. If residue conflicts with current ports/routing, it is handled as explicit LAB maintenance outside PRODUCT and cannot become a PRODUCT migration/startup prerequisite.

Cloudflare One Agent is the only Android VPN/VpnService owner. Windows-side external software may remain part of an E4 fixture, but Android PRODUCT contains no sing-box dataplane or compatibility runtime.

## Fail-closed acceptance

For public proxy targets, acceptance must never infer success from structural readiness alone when the stage requires real egress proof.

Required stable invariants include:

```text
exact Cellular authority for target DNS/public sockets
NO Wi-Fi public-egress fallback
NO Android default-route fallback
NO WARP/Cloudflare public-egress fallback
fresh generation proof after cellular loss/recovery
```

When the cellular authority becomes missing, stale or ambiguous, new target egress must fail closed.

## Protocol and capacity acceptance

The canonical proxy surface is:

```text
:1080 mixed ingress
:1081 SOCKS5
:3128 HTTP CONNECT
```

The active roadmap stage decides which protocol/auth/relay/capacity/resource facts must be reproven physically. Hosted Rust tests may establish deterministic protocol semantics, but they do not replace a required real-device topology claim.

For the U2 Mesh -> existing-Tokio convergence, exact-head E1 acceptance must prove all of the following on the same ready PR head before merge:

```text
architecture constitution PASS
Kotlin + generated UniFFI compile/lint PASS
Rust fmt/clippy/workspace tests PASS
positive Mesh listener -> loopback backend -> bidirectional byte relay PASS
64 admitted Mesh sessions + 65th rejected before backend PASS
backend-connect failure releases the Transport-owned session lease PASS
Mesh cancellation drains sessions PASS
fresh Mesh generation can restart on the same process Tokio runtime PASS
Android NDK/native packaging + unit tests + debug APK/androidTest assembly PASS
exact PRODUCT candidate contract PASS
```

The architecture guard must also make the convergence one-way: `mish-transport` cannot regain listener/session threads or relay execution; Mesh cannot create a second Tokio runtime or external capacity counter; Android cannot own a duplicate Mesh session counter.

## Evidence hygiene

Durable evidence must be typed, bounded and sanitized.

Do not persist:

- credentials or credential material;
- raw carrier/public IPs unless an explicit local-only UI requirement needs them;
- unrelated logcat;
- device serials/identifiers;
- secret provider material;
- unbounded process/environment dumps.

Lab evidence is immutable per-run evidence only. It is not a mutable runtime readiness database or second product-state authority.

## Authority

- accepted PRODUCT + CONTROL source: protected `main`;
- stage order and exit criteria: `PRODUCT_ROADMAP.md`;
- live stage/open PR/evidence ids: Issue #135;
- development candidate/DEVICE-1 mechanics: `DEVELOPMENT_PIPELINE.md` + executable workflows;
- formal release acceptance: `RELEASE.md`;
- physical execution boundary: `docs/lab/PLAN.md`;
- architecture: `SYSTEM.md`, `DEPENDENCIES.md`, `OWNERSHIP.md`.
