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
  -> sing-box (:1080 / :1081 / :3128)
  -> Cellular Egress owner
  -> exact cellular DNS/socket path
  -> LTE/5G Internet
```

Cloudflare Local Proxy / WarpProxy on Windows is not part of this path. Split Tunnel is destination-based and must not be treated as per-process enforcement. Final selected-application fail-closed behavior requires its own Windows enforcement proof.

This document is intentionally an execution contract only. The E4 workflow must not be enabled as an acceptance gate until Proxy Serving and Transport Reachability are implemented. Creating a fake checker earlier would violate `NO_EVIDENCE_ESCALATION`.

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
            |- Cloudflare One Agent
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

Mesh reachability
  Windows -> actual Android Mesh IP:proxy port

proxy protocol/auth
  :1080 mixed HTTP/SOCKS5 where supported by product contract
  :1081 SOCKS5
  :3128 HTTP + HTTPS CONNECT
  correct credentials accepted
  wrong/missing credentials rejected

cellular-only egress
  Wi-Fi connected simultaneously
  proxy/browser-visible public IP is carrier egress
  target DNS is resolved through the Android cellular-owned path where required
  cellular loss does not silently continue over Wi-Fi/default/WARP

real clients
  Kameleo launch/navigation through the Android Mesh proxy endpoint
  Camoufox launch/navigation through the Android Mesh proxy endpoint

selected-app fail-closed
  proxy unavailable -> no direct fallback
  Windows Cloudflare unavailable -> no direct fallback
  sing-box unavailable -> no direct IPv4/IPv6/UDP fallback
  no direct QUIC/WebRTC path outside the admitted proxy route

recovery
  Windows One Client/Mesh reconnect
  Android One Agent/Mesh reconnect
  cellular reconnect
  product does not restore stale READY
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
