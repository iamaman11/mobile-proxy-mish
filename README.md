# mobile-proxy-mish

Industrial rooted-Android mobile proxy appliance built around Cloudflare Mesh ingress and phone-owned cellular public egress.

## Reconstruct the project from GitHub

GitHub is the only durable source of truth.

Start here:

1. fresh protected `main` — this is the latest accepted PRODUCT + CONTROL source;
2. [`docs/architecture/SOURCE_OF_TRUTH.md`](docs/architecture/SOURCE_OF_TRUTH.md);
3. [`docs/architecture/PRODUCT_ROADMAP.md`](docs/architecture/PRODUCT_ROADMAP.md) for ordered product direction;
4. fresh Issue #135 for the current stage, open implementation PR if any, and immutable evidence ids;
5. inspect an open PR head only as the candidate currently under review, never as a second accepted product source.

## Current canonical PRODUCT path

```text
Kameleo / Camoufox
        ↓
Cloudflare One Client
        ↓
Cloudflare Mesh
        ↓
Cloudflare One Agent on Android
        ↓
Rust Transport / Mesh ingress
        ↓
in-process Rust Proxy Serving (:1080 / :1081 / :3128)
        ↓
Cellular Egress owner
        ↓
validated direct-cellular authority
        ↓
exact-network target DNS + root-policy-gated public socket
        ↓
LTE/5G Internet
```

There is no Android sing-box PRODUCT dataplane after L8. Historical Android proxy processes/files on a development phone are LAB hygiene only and never become PRODUCT startup, migration or recovery state.

Cloudflare One Agent is the only Android VPN/VpnService owner. Public proxy target egress has no Wi-Fi/default/WARP fallback.

## Core architecture

```text
one fact -> one natural owner -> one write path -> one observation path
```

```text
Android / Kotlin
  thin platform + effect + projection boundary
        ↓
thin UniFFI
        ↓
Rust mish-runtime
  runtime generation/lifecycle
  Tokio listener/session/task tree
  terminal failure/recovery
        ↓
  mish-proxy        protocol/auth/target semantics
  Cellular Egress   admission/currentness/DNS/socket authority
  Transport         Mesh/private transport
  Readiness         derived projection only
  Credentials       credential lifecycle
```

Prefer an existing natural owner plus one narrow adapter. Do not add a framework, daemon, generic root control API, second VPN/TUN, second lifecycle/readiness/cellular owner, mutable status DB or fallback egress path without a demonstrated requirement.

## Architecture navigation

- [Source-of-truth / reconstruction map](docs/architecture/SOURCE_OF_TRUTH.md)
- [Product roadmap](docs/architecture/PRODUCT_ROADMAP.md)
- [Executor policy](AGENTS.md)
- [System and process model](docs/architecture/SYSTEM.md)
- [Capability ownership](docs/architecture/OWNERSHIP.md)
- [Allowed dependency graph](docs/architecture/DEPENDENCIES.md)
- [Contract boundaries](docs/architecture/CONTRACTS.md)
- [Development execution policy](docs/architecture/EXECUTION.md)
- [Development CI and DEVICE-1 contract](docs/architecture/DEVELOPMENT_PIPELINE.md)
- [Readiness and acceptance](docs/architecture/ACCEPTANCE.md)
- [Build/release contract](docs/architecture/RELEASE.md)
- [Managed physical lab plan](docs/lab/PLAN.md)

Issue #135 is the single live execution/checkpoint pointer. Issue #134 is historical research/rationale.

## Development process

Canonical development loop:

```text
fresh main
 -> short owner-aligned PR to main
 -> exact-head hosted gate
 -> explicit physical Device Cycle only when the next required fact is physical
 -> typed immutable evidence
 -> STOP_FOR_ANALYSIS
 -> smallest correction if required
 -> merge accepted change to main
```

A successful build, merge, label or artifact publication never starts DEVICE-1 automatically. The Windows LAB consumes exact hosted artifacts in the normal path; it does not rebuild Android PRODUCT locally.

For a pre-merge physical cycle, evidence records the exact candidate `PRODUCT_SHA` and protected-main `CONTROL_SHA`. That is provenance only; after acceptance and merge, protected `main` is again the single accepted PRODUCT + CONTROL source.

Development debug candidates are not formal RC/release identity. Formal promotion follows the immutable release contract in `RELEASE.md`.
