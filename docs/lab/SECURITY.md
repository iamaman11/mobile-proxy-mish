# Physical lab security boundary

The physical lab exists to execute accepted code against real Windows/Android/Cloudflare/carrier reality. It is not a privileged development shell for unreviewed pull requests and is not an Android release-signing/build authority.

## Threat model

This repository is public. A persistent self-hosted runner has access to local machine state, attached devices and any credentials installed on that host. Terraform configuration is also executable enough to exfiltrate credentials through providers/provisioners. Android release-signing material is long-lived product authority and must likewise never be exposed to untrusted PR execution or the physical lab host. Therefore untrusted code must never be able to select the physical runner or receive provider/release credentials.

The main threats are:

- untrusted PR code executing on the lab host;
- untrusted PR Terraform receiving provider/R2 credentials;
- Android release keystore/private-key material reaching PR jobs or the physical runner;
- credentials leaking through logs/artifacts/process environment;
- Cloudflare provider write authority being reachable from the physical host;
- a persistent runner retaining stale files between jobs;
- ADB/root/device identifiers being recorded in public evidence;
- a custom local daemon turning into an undocumented remote-control plane.

## Runner policy

Normal repository CI and Android release construction remain GitHub-hosted.

```text
pull_request static CI       -> GitHub-hosted, no provider/release credentials
push/main CI                 -> GitHub-hosted
Android release build/sign   -> restricted GitHub-hosted release environment only
credentialed provider plan   -> GitHub-hosted, accepted protected main only
provider apply               -> GitHub-hosted, accepted protected main only
physical evidence            -> dedicated self-hosted Windows lab runner
```

Physical workflows must:

- use explicit self-hosted labels that normal CI never references;
- be manual/protected acceptance workflows;
- reject non-main refs;
- verify the checked-out commit is the intended accepted identity before a device/vendor effect;
- resolve/download/verify the exact selected immutable release asset rather than rebuilding it;
- serialize execution where the same device/account is shared;
- use bounded timeouts and explicit cancellation/failure handling;
- clean run-generated sensitive temporary files before completion where practical.

Credentialed provider workflows must also reject non-main/unaccepted refs. Pull requests may run only credential-free `terraform fmt`, `terraform validate`, schema/policy checks and other static validation. Android release-signing credentials are available only to the restricted release job after the immutable RC tag gate; ordinary PR/main CI must not receive them.

## Host separation

Recommended layout:

```text
C:\mish-lab\runner\
C:\mish-lab\tools\
C:\projects\mobile-proxy-mish\   # optional human clone only
```

The runner owns its own `_work` checkout. A human development clone is never used as physical evidence identity.

Prefer a dedicated Windows account for the runner with only the local rights required by the accepted workflows. Do not make Cloudflare provider credentials or Android release-signing material generally available to that account.

## Credential split

### Physical runner may have

Only credentials materially required for the physical fixture and only when their supported deployment path requires them. Prefer interactive/vendor-managed enrollment over durable secrets on disk.

### Physical runner must not have

- Cloudflare Terraform plan/apply API token;
- R2 Terraform-state credentials;
- Android release keystore/private key;
- Android release keystore/key passwords or release-signing aliases;
- broad GitHub write token/PAT;
- unrelated repository/provider secrets;
- production fleet credentials.

### Hosted Android release job

Android release-signing material belongs only to the restricted GitHub `android-release` environment and is materialized ephemerally in the GitHub-hosted release job. The job must fail closed if the signing secret set is incomplete, must not log private signing material, and must remove its temporary keystore after the job. The final signed APK is hashed and published as immutable versioned release bytes; the signing private key itself is never an artifact.

### Hosted provider jobs

Cloudflare desired-config credentials belong to protected GitHub-hosted provider workflows running accepted protected `main`. Use least privilege and separate read/plan from write/apply authority where practical. Never expose those credentials to PR-head Terraform execution.

## Public evidence redaction

Never persist:

```text
IMEI
IMSI
SIM/ICCID/phone number
Cloudflare enrollment/API tokens
proxy passwords
GitHub runner registration token
R2 credentials
Android release keystore/private key/passwords
private account identifiers when not required
Android ephemeral Network handles
unredacted secrets from command lines/environment
```

A public carrier IP should be validated when an acceptance contract requires it, but should not be persisted when the contract can record only that a valid IP literal was observed.

A release manifest may persist non-secret signing identity such as the signing-certificate SHA-256. That fingerprint is evidence/identity, not private signing material.

## Vendor boundary

Use supported Cloudflare/Android/Kameleo/Camoufox interfaces only. Do not make UI scraping, reverse engineering, private APIs or repackaged vendor binaries part of the lab control path.

## No remote-control daemon

Do not deploy an always-on custom command agent to the lab host merely so ChatGPT can trigger arbitrary local actions. The supported command path is GitHub Actions -> self-hosted runner -> versioned stateless `labctl`.

If a future operation cannot be expressed through that bounded path, treat it as a concrete architecture finding and decide its natural owner before adding another service.
