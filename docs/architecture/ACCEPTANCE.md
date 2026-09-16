# Readiness and acceptance

Runtime readiness is one pure derived projection over fresh owner observations:

```text
READY
NOT_READY
DEGRADED
UNKNOWN
```

Lifecycle is orthogonal. Missing or stale required observations become `UNKNOWN`; `UNKNOWN` never counts as success.

## Evidence levels

```text
E1  code / deterministic hosted CI
E2  Android emulator / bounded platform integration
E3  physical rooted Android + real carrier / real device topology
E4  Windows -> Cloudflare Mesh -> Android -> cellular -> external client full path
```

`NO_EVIDENCE_ESCALATION`: weaker evidence cannot close a stronger claim.

## Development physical evidence vs formal release evidence

Two physical paths exist and must not be conflated.

### Stage-specific development DEVICE-1 evidence

An exact-head debug candidate produced by `Integration Android Preflight` may be consumed by the explicit protected-main `Device Cycle` workflow before the PRODUCT lineage is merged to `main` when Issue #135 says the current stage requires that physical fact.

Such evidence is valid for the exact stage claim only when it records explicit provenance, including:

```text
PRODUCT_SHA
CONTROL_SHA
hosted candidate/run identity when applicable
physical run/evidence id
installed-byte/signature verification when installation is part of the claim
```

A `full` Device Cycle may therefore establish exact-candidate stage acceptance facts. `diagnose_only` and `probe_only` evidence are observations for analysis and do not prove that a requested PRODUCT candidate was installed/accepted.

Development debug evidence never becomes RC/release identity and cannot authorize release promotion.

### Formal E3/E4 release acceptance

Formal release/promotion uses immutable RC/release bytes under `RELEASE.md`:

```text
PIN -> BUILD ONCE -> HASH -> SIGN -> ATTEST -> TEST EXACT BYTES -> PROMOTE EXACT BYTES
```

No debug candidate may be relabeled as a release artifact or satisfy release-signing/promotion claims.

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

- stage order and exit criteria: `PRODUCT_ROADMAP.md`;
- live stage/exact implementation/evidence ids: Issue #135;
- development candidate/DEVICE-1 mechanics: `DEVELOPMENT_PIPELINE.md` + executable workflows;
- formal release acceptance: `RELEASE.md`;
- physical execution boundary: `docs/lab/PLAN.md`;
- architecture: `SYSTEM.md`, `DEPENDENCIES.md`, `OWNERSHIP.md`.
