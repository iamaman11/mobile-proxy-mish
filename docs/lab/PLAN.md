# Managed physical lab plan

This document defines the stable execution architecture for Cloudflare/bootstrap work and physical acceptance. Live stage status remains in GitHub Issues; this document must not become a second CURRENT pointer.

## Purpose

Create one controlled path from source to real-device evidence:

```text
GitHub
 -> protected/manual workflow
 -> one isolated Windows self-hosted lab runner
 -> repository-local stateless labctl
 -> supported Windows/Android/provider interfaces
 -> typed evidence back to GitHub
```

Product/runtime ownership does not move into the lab. Cloudflare, Android, carrier networks and vendor applications remain external live reality. GitHub remains the source/review/workflow/evidence control plane.

## Sequential pre-phone stages

Execute these in order:

```text
#23 LAB-0  repository/governance + evidence contract
 -> #24 CF-1  Cloudflare IaC/bootstrap authority
 -> #25 LAB-1 Windows lab host + isolated self-hosted runner
 -> #26 LAB-2 stateless labctl + unified workflow primitives
 -> #27 CF-2 Windows One Client + pre-phone Cloudflare validation
 -> #28 LAB-3 E3 pre-device cutover + dry proof
 -> PHONE-ON boundary
 -> #10 physical E3 full-root-toggle
```

Parent index: #22.

The sequence is deliberately serial where stages share provider, runner or evidence ownership. A later issue may be prepared in advance, but acceptance and live mutations must not leap over an unmet predecessor gate.

## Ownership

```text
Git/GitHub
  desired source, workflow definitions, review, immutable run/artifact evidence

Cloudflare
  live provider/transport state

Terraform
  normal declarative write path for supported Cloudflare desired configuration
  (its state is deployment machinery, not product/runtime truth)

Windows lab host
  physical execution environment only

GitHub self-hosted runner
  job transport into that host only

labctl
  stateless repository-owned execution adapter

Android / MISH runtime owners
  live product facts

E3 / E4 workflows
  acceptance ceremonies and evidence only
```

## What labctl is not

`labctl` must not become:

- an always-on daemon;
- an HTTP/RPC command service;
- a scheduler;
- an Issue-command router;
- a device registry;
- a mutable readiness/status database;
- a second product lifecycle owner.

It may invoke bounded subprocesses, ADB, build tools and supported vendor/client interfaces from a GitHub Actions job and serialize typed evidence for that run.

## Standard change paths

### Product / lab code

```text
short-lived branch -> PR -> required hosted CI -> squash merge -> accepted main
```

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
 -> manual/protected physical workflow
 -> isolated self-hosted Windows runner
 -> labctl
 -> real host/device/vendor observations
 -> typed/redacted GitHub evidence
```

## Phone-on boundary

The phone is not introduced until #23 through #28 are accepted. LAB-3 must leave the lab in a state where the only missing facts are truly device/physical facts.

At PHONE-ON:

```text
connect/power rooted arm64 Android
 -> authorize ADB
 -> verify API/ABI/root
 -> confirm real SIM + LTE/5G + validated Wi-Fi
 -> run #10 E3 full-root-toggle
```

Cloudflare One Agent/Mesh is not required to satisfy #10 E3 cellular proof. Android Mesh enrollment belongs to the later Transport/Mesh physical stage after the cellular E3 gate unless a concrete vendor prerequisite forces an earlier supported setup step.

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
  = only owner of proxy-target public DNS/socket creation
  = exact cellular Network-scoped DNS
  = bind the same exact cellular Network before connect
```

The physical acceptance must prove that Mesh ingress may remain available over Wi-Fi while proxy Internet egress is cellular-only. With Wi-Fi/Mesh still available and cellular lost/not admitted, the proxy request must fail closed; Wi-Fi/default/WARP/Cloudflare Internet fallback is forbidden. On cellular recovery a fresh authority generation is required before new target DNS/socket operations.

Android `Traffic and DNS` system-DNS behavior does not change this ownership: ordinary Android traffic may use the vendor-owned system DNS path, but MISH proxy target DNS must use the exact cellular Network authority rather than the Android default/system resolver.

These are stable architecture constraints, not a new roadmap stage. The actual Android One Agent profile, Mesh reachability and cellular/VpnService interaction remain physical evidence and must not be claimed before the phone exists.

## Non-negotiable constraints

```text
ONE_FACT_ONE_OWNER
NO_SECOND_CONTROL_PLANE
NO_MUTABLE_LAB_STATUS_DB
NO_UNTRUSTED_REF_ON_PHYSICAL_RUNNER
NO_PROVIDER_CREDENTIAL_ON_UNTRUSTED_REF
NO_PROVIDER_APPLY_SECRET_ON_PHYSICAL_RUNNER
NO_SECOND_ANDROID_VPN
NO_DEFAULT_WIFI_WARP_FALLBACK
NO_EVIDENCE_ESCALATION
NO_SECRET_OR_DEVICE_IDENTIFIER_PERSISTENCE
```

The repository is public. Physical and provider workflows therefore require stricter trust boundaries than ordinary hosted PR CI.
