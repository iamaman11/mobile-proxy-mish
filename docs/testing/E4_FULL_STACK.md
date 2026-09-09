# E4 — full external stack acceptance (future execution contract)

E4 is the first evidence domain that proves the intended product path end to end.

Windows precondition:

```text
ordinary Windows Internet
 -> sing-box TUN (default/full-tunnel owner)

Cloudflare Mesh/device destinations only
 -> Cloudflare One Client
 -> Traffic only / TunnelOnly
 -> MASQUE primary transport
 -> Cloudflare Mesh

Windows DNS
 -> existing sing-box/system path
 -> not Cloudflare DNS mode
```

Selected application path:

```text
Kameleo / Camoufox
  -> configured proxy at Android Mesh IP:proxy port
  -> Cloudflare Mesh
  -> Cloudflare One Agent on Android
  -> product-admitted Mesh ingress
  -> sing-box (:1080 / :1081 / :3128), proxy/server mode only
  -> Cellular Egress owner
  -> exact cellular Network-scoped DNS
  -> bind target socket to the same exact cellular Network before connect
  -> LTE/5G Internet
```

Cloudflare Local Proxy / WarpProxy on Windows is not part of this path. Split Tunnel is destination-based and must not be treated as per-process enforcement. Final selected-application fail-closed behavior requires its own Windows enforcement proof.

This document is intentionally an execution contract only. The E4 workflow must not be enabled as an acceptance gate until Proxy Serving and Transport Reachability are implemented. Creating a fake checker earlier would violate `NO_EVIDENCE_ESCALATION`.

## Android VPN ownership contract

Cloudflare One Agent is the only Android VPN/VpnService owner in Mesh mode. MISH/sing-box must not start a second Android TUN/VpnService.

```text
Cloudflare One Agent       -> Android VPN/private Mesh transport owner
sing-box on Android        -> proxy/server only; NO TUN/VpnService
MISH Cellular Egress       -> only owner allowed to create public proxy target DNS/sockets
```

Cloudflare One Agent may operate in `Traffic and DNS` and may own Android system DNS for ordinary Android traffic. That does not satisfy proxy-target DNS correctness. Proxy target DNS must use the owner-issued exact cellular Network authority, and the subsequent target socket must be bound to that same cellular Network before connect.

Cloudflare/Wi-Fi may carry the **Mesh ingress underlay** while LTE/5G carries the **proxy Internet egress**. These are intentionally different flows and must be observed independently.

The future Android profile should route only the Mesh/device destinations needed for private reachability where the supported mobile-client configuration permits it. Configuration alone never proves cellular egress; physical exact-network evidence remains mandatory.

## External fixtures are not product artifacts

The following components remain external vendor/test fixtures and are never repackaged into the MISH APK:

- Cloudflare One Agent on Android;
- Cloudflare One Client on Windows;
- Kameleo;
- Camoufox;
- Android OS / carrier network.

Acceptance treats them as black-box boundaries. Do not use UI scraping, reverse engineering, hidden vendor APIs, or copied vendor state as product truth.

Observed contract facts include only supported/non-secret facts such as:

```text
expected package/client present where observable
vendor version where supported
actual Mesh endpoint/reachability
actual TCP proxy flow
actual proxy authentication behavior
actual browser-visible public IP classification
```

## Recommended physical lab topology

```text
GitHub
  -> protected manual/release workflow
  -> self-hosted Windows acceptance runner
       |- sing-box TUN
       |- Cloudflare One Client (Traffic only / Mesh route owner)
       |- Kameleo
       |- Camoufox
       `- ADB access to physical Android phone
            |- MISH exact accepted artifact
            |- Cloudflare One Agent (only Android VPN owner)
            |- sing-box proxy/server mode only
            `- real SIM / LTE/5G + Wi-Fi as required by scenario
```

E3 may be executed through the accepted physical-lab path once its own stage is ready. E4 uses Windows because the real external client applications and the Windows route-ownership proof are part of the fixture.

## Required E4 scenario matrix

At minimum, the future workflow must prove:

```text
Windows route ownership
  ordinary IPv4 -> sing-box TUN
  ordinary IPv6 -> controlled policy, no silent physical fallback
  actual Mesh/device CIDR -> CloudflareWARP
  Windows DNS remains outside Cloudflare DNS mode

Android VPN ownership
  Cloudflare One Agent is the only active Android VPN/VpnService owner
  sing-box runs in proxy/server mode only
  no second Android TUN/VpnService exists

Mesh reachability
  Windows -> actual Android Mesh IP:proxy port
  Mesh may remain reachable over Wi-Fi while cellular state changes

proxy protocol/auth
  :1080 mixed HTTP/SOCKS5 where supported by product contract
  :1081 SOCKS5
  :3128 HTTP + HTTPS CONNECT
  correct credentials accepted
  wrong/missing credentials rejected

cellular-only egress positive
  Wi-Fi connected simultaneously
  cellular Network admitted by the natural owner
  target DNS resolved through the exact cellular Network
  target socket bound to the same exact cellular Network before connect
  proxy/browser-visible public IP classified as carrier egress
  no Android default/system/WARP/Wi-Fi target egress

cellular-only egress negative
  Wi-Fi remains connected
  Cloudflare One Agent/Mesh remains connected where possible
  cellular becomes unavailable/not admitted
  no cellular lease -> no target DNS/socket connect
  client request fails closed
  forbidden: Wi-Fi/default/WARP/Cloudflare Internet fallback

cellular recovery
  old authority remains invalid
  new cellular observation produces a fresh authority generation
  new target DNS/socket uses the fresh exact cellular Network
  carrier egress returns without restoring stale readiness

real clients
  Kameleo launch/navigation through the Android Mesh proxy endpoint
  Camoufox launch/navigation through the Android Mesh proxy endpoint

selected-app fail-closed on Windows
  proxy unavailable -> no direct fallback
  Windows Cloudflare unavailable -> no direct fallback
  Windows sing-box unavailable -> no direct IPv4/IPv6/UDP fallback
  no direct QUIC/WebRTC path outside the admitted proxy route

recovery
  Windows One Client/Mesh reconnect
  Android One Agent/Mesh reconnect
  cellular reconnect
  product does not restore stale READY
```

The decisive Android proof distinguishes two independent flows:

```text
Mesh ingress transport
  may use Wi-Fi / Cloudflare underlay

Proxy target Internet egress
  MUST use owner-issued exact cellular Network only
```

MASQUE is the primary Cloudflare transport for acceptance. Cloudflare One WireGuard is only a bounded fallback if a concrete MASQUE defect is demonstrated and must receive equivalent route/recovery evidence before use. A separate custom WireGuard mesh/control plane is outside this architecture.

Load/soak, reboot, rotation and longer recovery scenarios remain later release evidence as defined by A12 unless they become necessary to close a concrete E4 finding.

## GitHub evidence identity

Every E4 run must bind evidence to exact identities:

```text
Git commit / accepted artifact digest
MISH APK/native artifact digest
sing-box version + checksum
Android device model/build (non-secret)
Cloudflare One Agent version where supported
Cloudflare One Client version where supported
Cloudflare service mode + tunnel protocol
actual Mesh/device CIDR classification (non-secret)
Kameleo version
Camoufox version
scenario/timestamp
PASS/FAIL + typed failure reason
```

Never record IMEI, IMSI, SIM identifiers, passwords, enrollment tokens, Cloudflare account secrets, proxy credentials, or full diagnostic archives.

## Authority rule

```text
Git/GitHub = source, workflow, artifact and evidence authority
runtime owners = current product facts
Cloudflare/Android/carrier = live external reality
logs/metrics/test output = evidence only
```

E4 results never become a second runtime readiness owner.
