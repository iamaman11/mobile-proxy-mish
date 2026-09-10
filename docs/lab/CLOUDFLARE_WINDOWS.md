# CF-2 Windows Cloudflare One Client procedure

Issue #27 owns this stage. This document is an operator procedure, not a second current-stage pointer and not a Cloudflare desired-configuration owner.

## Purpose

CF-2 proves the Windows half of the future Mesh path before Android is introduced:

```text
ordinary IPv4
 -> existing non-Cloudflare Windows route owner

Mesh/device CIDR
 -> CloudflareWARP
 -> Cloudflare One Client
 -> Traffic only / TunnelOnly
 -> MASQUE

Windows DNS
 -> existing Windows/sing-box path
 -> not Cloudflare DNS mode
```

The accepted account-side profile and Mesh prerequisites remain owned by `infra/cloudflare/**` plus the protected hosted `Cloudflare Terraform Verify` path from CF-1. This stage does not apply Terraform, edit the dashboard, call hidden APIs, or create a second provider configuration path.

## Supported vendor boundary

Use only the official Cloudflare One Client and documented interfaces:

- install the current stable Windows Cloudflare One Client from Cloudflare;
- enroll through the official GUI or `warp-cli registration new <team-name>` flow as the interactive Windows user;
- inspect registration with `warp-cli registration show`;
- inspect applied policy with `warp-cli settings`;
- inspect connection state with `warp-cli status`;
- use `warp-cli connect` / `warp-cli disconnect` only for the bounded recovery proof;
- inspect Windows route selection with `Find-NetRoute` and the official `CloudflareWARP` virtual adapter.

Do not persist the organization/team name, profile ID, registration material, account ID, user identity, device identifier, diagnostic archive, DNS server addresses, or any authentication token in GitHub evidence. The repository probe records only allowlisted booleans, mode/protocol, current client version, route-interface aliases needed for ownership diagnosis, and the accepted Mesh/device CIDR.

## One-time installation and enrollment

LAB-1 deliberately did not install a browser/client package before a concrete consumer existed. CF-2 is the first owner that requires Cloudflare One Client.

Installation/enrollment is an external supported-user flow, not a self-hosted-runner secret path. The GitHub Actions service runs as `NT AUTHORITY\NETWORK SERVICE`; do not copy interactive enrollment tokens or IdP credentials into the runner, repository, workflow inputs, issues, or logs.

On the Windows lab host, as the interactive Windows user:

1. Install the current **stable** Cloudflare One Client from the official Cloudflare download page.
2. Enroll the client into the already-configured Zero Trust organization using the GUI, or run `warp-cli registration new <team-name>` and complete the browser authentication flow.
3. Verify locally that `warp-cli registration show` succeeds.
4. Connect the client if the accepted profile does not auto-connect.

Do not run local commands that rewrite the accepted device profile, Split Tunnel list, service mode, or tunnel protocol merely to make the physical proof pass. Those desired facts belong to the accepted Cloudflare profile/IaC path.

## Repository-owned physical proof

After the supported client is installed and enrolled, dispatch from protected `main`:

```text
Cloudflare Windows Pre-Phone Proof
```

The workflow has no user inputs and runs only on:

```text
[self-hosted, windows, x64, mobile-proxy-mish-lab]
```

It uses the accepted LAB-owned PowerShell runtime by absolute path and performs:

```text
protected-main host identity
 -> supported One Client registration/settings/status read-back
 -> require TunnelOnly
 -> require MASQUE
 -> require Split Tunnel Include of 100.96.0.0/12
 -> observe CloudflareWARP
 -> prove Mesh CIDR selects CloudflareWARP
 -> prove ordinary IPv4 does not select CloudflareWARP
 -> characterize ordinary IPv6 route ownership
 -> compare non-Cloudflare DNS configuration in memory
 -> disconnect Cloudflare One Client
 -> observe disconnected route state
 -> reconnect
 -> require split ownership + WARP route set + DNS state recover
 -> prove ADB device absent
 -> emit typed/redacted evidence
```

`100.96.0.0/12` is the current account-verified Mesh/device range adopted by CF-1. If the provider authority changes that range through an accepted change, update the repository proof in the same reviewed change; do not make the physical runner discover or rewrite provider desired configuration independently.

## What the proof deliberately does not claim

The physical probe records ordinary IPv4 as `NON_CLOUDFLARE_OBSERVED`; it does **not** upgrade that observation to `sing-box owned` merely because Cloudflare did not win the route.

The repository currently has no accepted Windows sing-box lifecycle owner, service name, configuration path, or stable interface-name contract. Therefore CF-2 must not invent one or run arbitrary `Stop-Process`/service commands. The remaining #27 DoD item for explicit sing-box ownership/restart requires a natural owner or direct physical fact before it can be accepted.

Likewise this proof does not claim:

```text
Android One Agent enrollment
Windows -> Android Mesh TCP
Android proxy serving
cellular egress
E3
E4
product READY
```

Phone/Android remains absent throughout CF-2.

## Evidence

Success writes one `mish.lab.evidence/v1` artifact named:

```text
cloudflare-windows-prephone-evidence
```

with `run_kind = cloudflare-windows-prephone`.

Evidence is immutable per run and never a mutable readiness database. A green hosted parser/static test proves only repository-side logic; CF-2 physical facts require the self-hosted Windows run.
