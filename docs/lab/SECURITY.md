# Physical lab security boundary

The physical lab executes explicitly authorized evidence against real Windows/Android/Cloudflare/carrier reality. It is not a privileged development shell for unreviewed PR code and is not an Android release-signing/build authority.

## Threat model

This repository is public. A persistent self-hosted runner can reach local machine state, attached devices and any credentials installed on that host. Terraform/provider authority and Android release-signing material are separately sensitive. Untrusted PR code must never select the physical runner or receive provider/release credentials.

Primary threats:

- untrusted code executing on the lab host;
- provider/R2 credentials reaching PR-head execution;
- Android release keys/passwords reaching PR jobs or the physical runner;
- credentials leaking through logs/artifacts/process environment;
- a persistent runner retaining sensitive state;
- ADB/root/device identifiers leaking into public evidence;
- a custom daemon becoming an undocumented remote-control plane;
- confusing an exact development PRODUCT candidate with formal release authority.

## Runner policy

Normal CI and Android release construction remain GitHub-hosted.

```text
pull_request/static/product CI   -> GitHub-hosted, no provider/release secrets
Android release build/sign       -> restricted GitHub-hosted release environment
credentialed provider plan/apply -> protected hosted path only
physical evidence                -> dedicated self-hosted Windows lab runner
```

There are two legitimate physical evidence classes.

### Development exact-head Device Cycle

The self-hosted runner executes only through the protected-main `Device Cycle` workflow after an explicit owner `/mish-cycle` request.

The control workflow itself is protected-main `CONTROL_SHA`; the selected PRODUCT may be an exact accepted/current integration-head candidate identified by `PRODUCT_SHA` and Issue #135.

Before any install/device effect, the workflow must verify the exact request, current integration lineage, accepted producer workflow, completed successful hosted candidate and exact artifact identity/digest. The physical runner consumes those exact bytes and does not rebuild Android PRODUCT locally.

No successful build, merge, label or artifact publication automatically starts DEVICE-1.

### Formal release acceptance

Formal release physical acceptance resolves/downloads/verifies exact immutable RC/release bytes under `RELEASE.md`. Release-signing secrets never reach the physical runner.

## Physical workflow requirements

Physical workflows must:

- use explicit self-hosted labels that ordinary CI never references;
- be explicitly authorized/manual or otherwise protected by the accepted control workflow;
- execute versioned control scripts from an exact protected `CONTROL_SHA`;
- verify exact PRODUCT/artifact identity before PRODUCT/device effects;
- serialize when the same device/account is shared;
- use bounded timeouts and fail closed on ambiguous identity/provenance;
- produce bounded sanitized immutable evidence;
- clean generated sensitive temporary material where practical;
- never automatically select a repair/follow-up cycle after a result.

Provider write workflows remain protected hosted paths. Pull requests may run only credential-free static/provider validation. Android release-signing credentials are available only to the restricted release job after its release gate.

## Host separation

Recommended layout:

```text
C:\mish-lab\runner\
C:\mish-lab\tools\
C:\projects\mobile-proxy-mish\   # optional human clone only
```

The runner owns its own `_work` checkout. A human development clone is never evidence identity.

Prefer a dedicated Windows runner identity with only the local rights needed by accepted workflows. Do not make Cloudflare provider credentials or Android release-signing material generally available to that identity.

## Credential split

### Physical runner may have

Only credentials materially required for the physical fixture and only through their accepted supported path. Prefer vendor-managed/interactive enrollment over unrelated durable secrets.

### Physical runner must not have

- Cloudflare Terraform plan/apply API token;
- R2 Terraform-state credentials;
- Android release keystore/private key;
- Android release keystore/key passwords or release-signing aliases;
- broad GitHub write PAT;
- unrelated repository/provider secrets;
- production fleet credentials.

### Hosted Android release job

Android release-signing material belongs only to the restricted GitHub release environment and is materialized ephemerally in the hosted release job. The job fails closed if its signing set is incomplete, never logs private signing material, removes temporary key material, and publishes only the final signed APK plus non-secret identity/digests/attestation.

### Hosted provider jobs

Provider desired-config credentials belong to protected hosted workflows under least privilege. Never expose them to PR-head Terraform execution or the physical runner merely to simplify orchestration.

## Public evidence redaction

Never persist:

```text
IMEI
IMSI
SIM/ICCID/phone number
Cloudflare enrollment/API tokens
proxy passwords or credential material
GitHub runner registration token
R2 credentials
Android release private key/passwords
private account identifiers when not required
Android ephemeral Network handles
unredacted secret-bearing command lines/environment
```

When a public IP must be validated, prefer a typed assertion/digest/change fact instead of persisting the literal unless a specific local-only product requirement needs the value.

A signing-certificate SHA-256 is non-secret artifact identity and may be persisted.

## Current Android PRODUCT security boundary

Cloudflare One Agent is the only Android VPN/VpnService owner. MISH PRODUCT runs its current proxy dataplane in-process in Rust and has no Android sing-box compatibility/process-management runtime.

Historical `/data/adb/mobile-proxy-node` or similar root residue is LAB hygiene only. It is never a reason to grant PRODUCT a generic process-scan/kill/control capability.

PRODUCT root authority uses one persistent Magisk `su` transport beneath narrow typed effects. Do not replace this with a generic privileged daemon/RPC service merely for lab convenience.

## No remote-control daemon

Do not deploy an always-on custom command agent to the lab host merely so ChatGPT can trigger arbitrary actions. The supported durable path is GitHub Actions -> protected control workflow -> self-hosted runner -> versioned bounded scripts.

A local interactive agent may perform one explicitly bounded diagnostic when current repository tooling cannot establish a required physical fact. It is not a persistent control plane or source of truth; sanitized conclusions return to GitHub evidence/#135.
