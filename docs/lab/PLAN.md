# Managed physical lab plan

This document defines the stable execution architecture for Cloudflare/bootstrap work and physical acceptance. Live stage status remains in GitHub Issues; this document must not become a second CURRENT pointer.

## Purpose

Create one controlled path from source to real-device evidence:

```text
Git source
 -> GitHub-hosted CI / restricted release workflow
 -> exact versioned immutable Android RC/release bytes
 -> protected/manual physical workflow
 -> one isolated Windows self-hosted lab runner
 -> repository-local stateless labctl
 -> supported Windows/Android/provider interfaces
 -> typed evidence back to GitHub
```

Product/runtime ownership does not move into the lab. Cloudflare, Android, carrier networks and vendor applications remain external live reality. GitHub remains the source/review/workflow/evidence control plane. The physical Windows lab consumes exact published release bytes; it is not a second Android release-build authority.

All product/lab extensions must obey the application minimal-layer invariant in `docs/architecture/DEPENDENCIES.md`: use the existing natural owner plus one narrow adapter when that is sufficient; do not pre-build another owner, manager layer, daemon or control plane.

## Sequential pre-phone stages

Execute these in order:

```text
#23 LAB-0  repository/governance + evidence contract
 -> #24 CF-1  Cloudflare IaC/bootstrap authority
 -> #25 LAB-1 Windows lab host + isolated self-hosted runner
 -> #48 REL-1 versioned immutable Android RC/release artifact path
 -> #26 LAB-2 stateless labctl + release-consumer workflow primitives
 -> #27 CF-2 Windows One Client + pre-phone Cloudflare validation
 -> #28 LAB-3 E3 pre-device cutover + dry proof
 -> PHONE-ON boundary
 -> #10 physical E3 on exact accepted RC bytes
```

Parent index: #22.

The sequence is deliberately serial where stages share provider, runner, release or evidence ownership. A later issue may be prepared in advance, but acceptance and live mutations must not leap over an unmet predecessor gate.

## Ownership

```text
Git/GitHub
  desired source, workflow definitions, review, immutable run/evidence records

GitHub-hosted restricted release workflow
  Android release build/sign/package authority

GitHub Release exact version/tag + digest
  versioned binary distribution authority

Cloudflare
  live provider/transport state

Terraform
  normal declarative write path for supported Cloudflare desired configuration
  (its state is deployment machinery, not product/runtime truth)

Windows lab host
  physical execution environment and exact-release consumer only

GitHub self-hosted runner
  job transport into that host only

labctl
  stateless repository-owned execution adapter and exact-release verifier/consumer

Android / MISH runtime owners
  live product facts

E3 / E4 workflows
  acceptance ceremonies and evidence only
```

Root/network commands executed by LAB are test/evidence authority only. ADB/root shell success does not prove that PRODUCT itself owns the production root capability required by its runtime adapter.

## Release law

The accepted A13 supply-chain rule applies to every physical acceptance path:

```text
PIN
 -> BUILD ONCE
 -> HASH
 -> SIGN
 -> ATTEST
 -> TEST EXACT BYTES
 -> PROMOTE EXACT BYTES
```

Normal PR/main CI may build debug/test artifacts as source verification. Those are not release authority. A physical workflow must resolve an exact version/tag, download the named release asset, verify its manifest and digest, and test those bytes. `latest` is never machine acceptance identity.

Stable promotion may only reuse the exact signed RC bytes/digest already accepted physically. It must not run Gradle/Cargo again to manufacture a new stable artifact.

## What labctl is not

`labctl` must not become:

- an always-on daemon;
- an HTTP/RPC command service;
- a scheduler;
- an Issue-command router;
- a device registry;
- a mutable readiness/status database;
- a second product lifecycle owner;
- an Android release build system;
- a second artifact registry or release selector based on `latest`.

It may invoke bounded subprocesses, ADB and supported vendor/client interfaces from a GitHub Actions job, resolve/verify exact release assets, and serialize typed evidence for that run. Optional local developer builds remain ordinary developer diagnostics and never create physical-acceptance or release identity.

## Standard change paths

### Product / lab code

The merge unit is an **evidence milestone**, not every internal implementation stage.

```text
fresh accepted main + current execution/natural-owner Issues
 -> draft integration PR
 -> accumulate all coherent E1/E2-completable work
 -> batch related remote edits/pushes
 -> direct tests at the cheapest valid evidence level
 -> deliberate exact-head hosted CI checkpoint(s)
 -> ready-for-review exact-head required CI PASS
 -> one squash merge at the milestone boundary
 -> accepted main
 -> fresh post-merge verification
```

Do not merge merely to record that lifecycle, credentials, Mesh ingress, DNS/readiness or another adjacent internal stage completed. Keep working in the draft integration PR while the next required fact can still be established correctly at E1/E2.

Cross `main` only when the coherent milestone is complete as far as E1/E2 can prove it, or when the next required fact genuinely needs accepted `main`, LAB, provider mutation or a release boundary.

Do not create a new layer merely to organize a change. If the existing owner plus one narrow adapter can solve it correctly, that is the required default shape.

### Development physical diagnostic

The development-only LAB convenience accepts **one exact accepted green PRODUCT `main` SHA**. It does not build or test arbitrary PR branches.

Therefore:

```text
E1/E2 work still available
 -> remain in draft integration PR
 -> do not merge for progress

next implementation decision requires an irreducible physical fact
 -> finish all independent E1/E2 work first
 -> exact-head CI
 -> one milestone merge
 -> verify green main
 -> request only the bounded physical fact required by Issue #86 / natural owner
```

A LAB candidate is not requested merely because a PR merged. Physical evidence is created only when a stronger evidence boundary is actually required.

### Android release candidate

```text
accepted source/version
 -> restricted GitHub-hosted release workflow
 -> build/sign once
 -> final APK SHA-256 + release manifest
 -> exact versioned GitHub prerelease
 -> exact-tag readback and byte verification
 -> downstream physical consumer
```

Release-signing private material belongs only to the restricted GitHub release environment. It must not be committed, exposed to ordinary PR jobs, or copied to the physical lab runner.

### Cloudflare supported desired configuration

Because Terraform configuration can execute providers/provisioners, Cloudflare credentials are never exposed to an untrusted PR head in this public repository.

```text
PR -> hosted terraform fmt/validate with NO provider credentials
 -> review
 -> squash merge to accepted main
 -> credentialed hosted terraform plan on that exact accepted main
 -> inspect immutable plan evidence
 -> protected/manual apply from the same accepted main identity
 -> fresh provider read-back
 -> GitHub evidence
```

A credentialed plan is intentionally post-merge. If it reveals an unexpected provider delta, do not apply; correct desired config in a new PR and repeat.

One-time provider bootstrap steps that cannot yet be represented safely as IaC must be explicitly documented as bootstrap exceptions. They must not silently remain a permanent parallel dashboard write path.

### Physical execution

```text
accepted protected main
 + exact RC/release version/tag + expected digest
 -> manual/protected physical workflow
 -> isolated self-hosted Windows runner
 -> labctl resolve/download/verify exact release bytes
 -> real host/device/vendor observations
 -> typed/redacted GitHub evidence
```

No Gradle/Cargo rebuild may substitute for the selected published release asset.

## Phone-on boundary

The phone is not introduced until #23, #24, #25, #48, #26, #27 and #28 are accepted. LAB-3 must leave the lab in a state where the only missing facts are truly device/physical facts.

At PHONE-ON for the current fixed device profile:

```text
select exact accepted RC version/tag + digest
 -> connect/power rooted Samsung SM-A022G / Android 11 / API 30 / armeabi-v7a
 -> authorize ADB
 -> verify exact API/ABI/root and package identity
 -> confirm real SIM + LTE/5G service
 -> record Wi-Fi state independently; Wi-Fi is not an E3 Cellular Egress prerequisite
 -> install/test the exact verified RC bytes
 -> prove PRODUCT-side root authority required by the accepted adapter
 -> run #10 E3 continuous positive -> loss -> recovery ceremony
```

For the root-policy replacement path, Cloudflare One Agent is installed and connected as a target-topology coexistence fixture. Its presence does not satisfy Mesh/E4 acceptance and the E3 workflow must not promote One Agent connectivity into a Transport Reachability claim.

## Cellular Egress physical mechanism boundary

The existing Cellular Egress capability remains the sole semantic owner of cellular admission, generation/currentness and availability. Root routing is a narrow infrastructure adapter to that owner.

Current evidence-backed mechanism shape:

```text
validated direct cellular authority
 -> intended proxy/runtime NEW outbound egress flow
 -> narrow owner-matched fwmark/mask
 -> RPDB lookup of the fresh direct-cellular routing table
 -> masked unreachable guard after the cellular lookup
 -> LTE/5G public egress
```

Rules for lab/acceptance work:

- do not treat historical `Network.bindSocket/android_setsocknetwork` as the canonical target mechanism; it failed `EPERM` on the real One Agent topology;
- do not globally replace Android default routing;
- do not assume whole-PRODUCT-UID routing is safe until loopback/Mesh-response behavior is proven;
- ADB root may perform bounded LAB mutations but cannot substitute for explicit PRODUCT runtime root authority;
- ambiguity, loss or stale generation must retain fail-closed protection rather than remove policy and fall through to main/default/Wi-Fi/WARP;
- unsupported/unvalidated IPv6 remains fail closed;
- temporary LAB rules must be exactly scoped and removed/verified after each experiment.

## Later Android Mesh/transport gate

When the later Transport/Mesh stage is reached, the Android-side ownership is already constrained and must not be reinvented:

```text
Cloudflare One Agent
  = the only Android VPN/VpnService owner

sing-box on Android
  = proxy/server only
  = NO TUN / NO VpnService

Cloudflare Mesh
  = private ingress transport only

MISH Cellular Egress
  = only semantic owner of proxy-target public egress authority

root policy-routing adapter
  = infrastructure mechanism only
  = intended proxy egress -> direct-cellular table
  = unreachable guard on loss/ambiguity

proxy-target DNS
  = cellular-owned path
  = final resolver/anti-leak acceptance belongs to #64
```

The physical acceptance must prove that Mesh ingress may remain available over Wi-Fi/Cloudflare underlay while proxy Internet egress is cellular-only. With Mesh still available and cellular lost/not admitted, the proxy request must fail closed; Wi-Fi/default/WARP/Cloudflare Internet fallback is forbidden. On cellular recovery a fresh authority generation and fresh policy reconciliation are required before new target egress.

Android `Traffic and DNS` system-DNS behavior does not change this ownership: ordinary Android traffic may use the vendor-owned system DNS path, but MISH proxy target DNS must follow the cellular-owned egress policy rather than silently falling back to the Android default/system resolver. Issue #64 owns the final DNS mechanism/anti-leak proof.

These are stable architecture constraints, not a new roadmap stage. Actual Mesh reachability, PRODUCT root authority, lifecycle reconciliation and DNS anti-leak remain physical evidence and must not be claimed before their respective gates pass.

## Non-negotiable constraints

```text
ONE_FACT_ONE_OWNER
NO_SECOND_CONTROL_PLANE
NO_MUTABLE_LAB_STATUS_DB
NO_UNTRUSTED_REF_ON_PHYSICAL_RUNNER
NO_PROVIDER_CREDENTIAL_ON_UNTRUSTED_REF
NO_PROVIDER_APPLY_SECRET_ON_PHYSICAL_RUNNER
NO_RELEASE_SIGNING_SECRET_ON_PHYSICAL_RUNNER
NO_PHYSICAL_ANDROID_RELEASE_BUILD
NO_LATEST_RELEASE_AUTHORITY
NO_SECOND_ANDROID_VPN
NO_DEFAULT_WIFI_WARP_FALLBACK
NO_EVIDENCE_ESCALATION
NO_SECRET_OR_DEVICE_IDENTIFIER_PERSISTENCE
```

The repository is public. Physical, provider and release-signing workflows therefore require stricter trust boundaries than ordinary hosted PR CI.
