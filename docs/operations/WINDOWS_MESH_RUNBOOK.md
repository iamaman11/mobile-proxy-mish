# Windows Mesh outage and bounded WARP session recovery

This is an **operator runbook**, not a second PRODUCT authority or an automatic recovery controller.
Current runtime state must be measured; old incident runs are historical evidence only.
Canonical commands are defined by the workflows on protected `main`, and the sole authorized
operator comment surface is GitHub Issue [#163](https://github.com/iamaman11/mobile-proxy-mish/issues/163).

## Scope and non-negotiable boundaries

- Client path: Windows application -> Cloudflare One Client/WARP -> Cloudflare Mesh ->
  Android Cloudflare One Agent -> Rust Proxy ports `1080/1081/3128` -> direct Cellular Egress.
- Windows ordinary Internet/sing-box default tunnel and Cloudflare Mesh CIDR routing are
  distinct owners. `WARP Connected` is **not** proof of Mesh TCP or authenticated Proxy E2E.
- Diagnosis never changes mobile data, IP Rotation, Android PRODUCT, root policy, signing
  identity, proxy credentials, Cloudflare settings, or Windows default Internet route.
- No auto-reconnect loop, service restart, WARP re-registration, alternate public egress, APK
  reinstall or second VPN owner. On an unexpected state, **stop and investigate**.

## Read-only fault isolation

Submit each exact comment to Issue #163 from the authorized repository owner, **one at a time**.
Wait for its matching run to finish before posting the next command: the diagnostic workflow
shares a concurrency group and queued runs may be superseded.

1. `/mish-diag snapshot`: require an already-running PRODUCT; inspect runtime, Cellular
   admission, root authorization, Proxy health, Android Mesh ingress, Android readiness and
   two independent authenticated E2E paths (ADB-loopback and Windows Mesh). If loopback
   fails, do **not** blame WARP or run WARP recovery.
2. `/mish-diag warp-state`: inspect WARP connection/mode/protocol, running service, adapter,
   Cloudflare-owned Mesh route and the actual Windows -> DEVICE TCP `:3128`.
3. `/mish-diag mesh-route` when attribution is ambiguous: inspect Windows-selected route
   interface and TCP interface to the current DEVICE Mesh address.
4. `/mish-diag control-snapshot` when manager/control failure is suspected; CONTROL and
   Proxy/Mesh are independent failure domains.
5. `/mish-diag provider-state` only when an Android process/provider failure is suspected.
   `/mish-diag cloudflare-live` is a separate read-only provider-configuration preflight;
   a settings drift is **not** sufficient to diagnose the Windows session.

Diagnostic GitHub Actions status `success` means **evidence collection succeeded**; inspect
the typed `classification` and both E2E results. A read-only run may succeed while dataplane
classification is `FAIL`. Never claim a healthy proxy from workflow green status alone.

## One authorized recovery

Only if a fresh snapshot reports `WINDOWS_MESH_TCP_3128_UNREACHABLE` while Android PRODUCT
is RUNNING/READY and authenticated ADB-loopback proxy E2E is PASS, **and** a fresh WARP
diagnostic reports `WARP_MESH_TCP_3128_UNREACHABLE` with Cloudflare-owned route, WARP
connected and TCP `:3128` unreachable:

1. Post the single exact command `/mish-maint warp-reconnect` to Issue #163.
2. The protected-main `mish-warp-session-recovery.yml` independently rechecks the same
   preconditions and, only if they still match, executes **one** Windows WARP disconnect/
   reconnect primitive. It does not modify Cloudflare provider configuration or PRODUCT.
3. Inspect its immutable evidence. Require `WARP_SESSION_RECOVERED`, recovery_cycles=1,
   post-WARP classification `READY`, and post-device classification `PASS`, with
   authenticated Windows Mesh Proxy E2E PASS and TCP `1080/1081/3128` reachable.
4. If preconditions change, recovery fails, or post-E2E is not PASS: **stop**. Preserve the
   run's sanitized artifact and investigate read-only; do not blindly retry.

Historical successful example (2026-10-24, not a live health claim):
[WARP Session Recovery #55](https://github.com/iamaman11/mobile-proxy-mish/actions/runs/40126808030).
Its evidence changed Windows Mesh TCP `:3128` and authenticated Mesh E2E from FAIL to PASS
with one WARP reconnect while Android PRODUCT stayed healthy.

## Separate debts and escalation

- [#431](https://github.com/iamaman11/mobile-proxy-mish/issues/431) owns Windows Zero Trust
  profile `allow_mode_switch` drift. It did **not** explain the confirmed stale-session
  incident. A provider write requires a separately authorized credential and exact one-field
  change followed by readback; this runbook does **not** authorize that write.
- [#340](https://github.com/iamaman11/mobile-proxy-mish/issues/340) owns self-hosted runner
  GitHub broker/TLS transport. A queued action or offline runner is **not** proof of PRODUCT
  failure. Do not automatically restart/re-register the runner to mask the cause.
- Repeated WARP outages require a separate evidence-first root-cause investigation using
  bounded Windows WARP/TLS/route/session logs correlated to the failure window. No automatic
  mutation is authorized by this document.

## Evidence and stop condition

Record only run URLs, SHA, typed classifications, pre/post E2E results and approved sanitized
artifacts. Do not copy raw public IPs, authentication material, full device logcat or private
identifiers into issues. Stop when the specific operator need is resolved; do not start IP
Rotation, Device Cycle installation, recovery retries or unrelated diagnostics for housekeeping.
