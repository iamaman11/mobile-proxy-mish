# Physical lab security boundary

The physical lab exists to execute accepted code against real Windows/Android/Cloudflare/carrier reality. It is not a privileged development shell for unreviewed pull requests.

## Threat model

This repository is public. A persistent self-hosted runner has access to local machine state, attached devices and any credentials installed on that host. Therefore untrusted code must never be able to select the physical runner.

The main threats are:

- untrusted PR code executing on the lab host;
- credentials leaking through logs/artifacts/process environment;
- Cloudflare provider write authority being reachable from the physical host;
- a persistent runner retaining stale files between jobs;
- ADB/root/device identifiers being recorded in public evidence;
- a custom local daemon turning into an undocumented remote-control plane.

## Runner policy

Normal repository CI remains GitHub-hosted.

```text
pull_request       -> GitHub-hosted only
push/main CI       -> GitHub-hosted only unless a workflow is explicitly physical
provider plan/apply-> GitHub-hosted only
physical evidence  -> dedicated self-hosted Windows lab runner
```

Physical workflows must:

- use explicit self-hosted labels that normal CI never references;
- be manual/protected acceptance workflows;
- reject non-main refs;
- verify the checked-out commit is the intended accepted identity before a device/vendor effect;
- serialize execution where the same device/account is shared;
- use bounded timeouts and explicit cancellation/failure handling;
- clean run-generated sensitive temporary files before completion where practical.

## Host separation

Recommended layout:

```text
C:\mish-lab\runner\
C:\mish-lab\tools\
C:\projects\mobile-proxy-mish\   # optional human clone only
```

The runner owns its own `_work` checkout. A human development clone is never used as physical evidence identity.

Prefer a dedicated Windows account for the runner with only the local rights required by the accepted workflows. Do not make Cloudflare provider credentials generally available to that account.

## Credential split

### Physical runner may have

Only credentials materially required for the physical fixture and only when their supported deployment path requires them. Prefer interactive/vendor-managed enrollment over durable secrets on disk.

### Physical runner must not have

- Cloudflare Terraform/apply API token;
- R2 Terraform-state credentials;
- broad GitHub write token/PAT;
- unrelated repository/provider secrets;
- production fleet credentials.

### Hosted provider jobs

Cloudflare desired-config credentials belong to protected GitHub-hosted provider workflows. Use least privilege and separate read/plan from write/apply authority where practical.

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
private account identifiers when not required
Android ephemeral Network handles
unredacted secrets from command lines/environment
```

A public carrier IP should be validated when an acceptance contract requires it, but should not be persisted when the contract can record only that a valid IP literal was observed.

## Vendor boundary

Use supported Cloudflare/Android/Kameleo/Camoufox interfaces only. Do not make UI scraping, reverse engineering, private APIs or repackaged vendor binaries part of the lab control path.

## No remote-control daemon

Do not deploy an always-on custom command agent to the lab host merely so ChatGPT can trigger arbitrary local actions. The supported command path is GitHub Actions -> self-hosted runner -> versioned stateless `labctl`.

If a future operation cannot be expressed through that bounded path, treat it as a concrete architecture finding and decide its natural owner before adding another service.
