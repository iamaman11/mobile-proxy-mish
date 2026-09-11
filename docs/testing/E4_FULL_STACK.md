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
  -> validated direct-cellular authority
  -> PRODUCT root policy-routing adapter
  -> intended proxy-egress flow -> current direct-cellular table
  -> fail-closed unreachable guard behind that lookup
  -> cellular-owned target DNS + public connection
  -> LTE/5G Internet
```

Cloudflare Local Proxy / WarpProxy on Windows is not part of this path. Split Tunnel is destination-based and must not be treated as per-process enforcement. Final selected-application fail-closed behavior requires its own Windows enforcement proof.

This document is intentionally an execution contract only. The E4 workflow must not be enabled as an acceptance gate until Proxy Serving and Transport Reachability are implemented. Creating a fake checker earlier would violate `NO_EVIDENCE_ESCALATION`.

## Android VPN and egress ownership contract

Cloudflare One Agent is the only Android VPN/VpnService owner in Mesh mode. MISH/sing-box must not start a second Android TUN/VpnService.

```text
Cloudflare One Agent       -> Android VPN/private Mesh transport owner
sing-box on Android        -> proxy/server only; NO TUN/VpnService
MISH Cellular Egress       -> semantic owner of public proxy egress admission/currentness
root policy-routing        -> narrow infrastructure adapter to Cellular Egress
proxy-target DNS           -> cellular-owned path; final resolver/anti-leak acceptance in #64
```

Cloudflare One Agent may operate in `Traffic and DNS` and may own Android system DNS for ordinary Android traffic. That does not satisfy proxy-target DNS correctness. Proxy target DNS/public sockets must follow the same admitted cellular egress policy and must not silently use Android default/system/WARP/Wi-Fi egress.

The earlier exact-network per-socket binding seam is historical implementation evidence, not the E4 target contract. On the target One Agent topology, `Network.bindSocket/android_setsocknetwork` failed `EPERM`; the accepted implementation direction is lifecycle-bounded PRODUCT root policy-routing while retaining Cellular Egress as the sole semantic owner.

Cloudflare/Wi-Fi may carry the **Mesh ingress underlay** while LTE/5G carries the **proxy Internet egress**. These are intentionally different flows and must be observed independently.

The future Android profile should route only the Mesh/device destinations needed for private reachability where the supported mobile-client configuration permits it. Configuration alone never proves cellular egress; physical policy-routing/carrier evidence remains mandatory.

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
  Mesh remains reachable while cellular egress state changes where the fixture underlay permits it

proxy protocol/auth
  :1080 mixed HTTP/SOCKS5 where supported by product contract
  :1081 SOCKS5
  :3128 HTTP + HTTPS CONNECT
  correct credentials accepted
  wrong/missing credentials rejected

cellular-only egress positive
  Wi-Fi connected simultaneously
  Cloudflare One Agent/Mesh remains connected
  direct cellular Network admitted by the natural owner
  PRODUCT root authority is available to the accepted narrow adapter
  intended proxy-egress flow is selected by the accepted narrow policy
  current direct-cellular routing table is derived from fresh live state
  marked/direct-cellular route is validated
  fail-closed guard is present behind the cellular lookup
  target DNS/public connection follows the cellular-owned path
  proxy/browser-visible public IP classified as carrier egress
  no Android default/system/WARP/Wi-Fi target egress

cellular-only egress negative
  Wi-Fi remains connected
  Cloudflare One Agent/Mesh remains connected where possible
  cellular becomes unavailable/not admitted
  old owner generation becomes unusable
  unreachable protection prevents route fallthrough
  new target DNS/public connection fails closed
  forbidden: Wi-Fi/default/WARP/Cloudflare Internet fallback

cellular recovery
  old authority remains invalid
  new cellular observation produces a fresh authority generation
  direct-cellular routing target is rediscovered
  root policy is freshly reconciled and validated
  cellular-owned DNS/public egress returns
  stale readiness/policy is not restored

IPv6
  IPv6 may not bypass the cellular policy
  if no validated direct-cellular IPv6 path exists, proxy-target IPv6 fails closed
  if IPv6 is later supported, it receives equivalent route/fail-closed evidence

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
  PRODUCT/root policy reconciliation converges
  product does not restore stale READY
```

The decisive Android proof distinguishes two independent flows:

```text
Mesh ingress transport
  may use Wi-Fi / Cloudflare underlay

Proxy target Internet egress
  MUST follow current Cellular Egress authority
  -> PRODUCT-owned narrow root policy-routing adapter
  -> direct LTE/5G route
  -> fail closed on loss/ambiguity
```

Do not route the whole PRODUCT UID merely to satisfy E4 unless loopback and Mesh-response behavior has already been physically proven safe. Do not introduce a dedicated egress helper/process unless a concrete privilege/lifecycle/isolation fact proves it necessary under the minimal-layer invariant.

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

Never record IMEI, IMSI, SIM identifiers, passwords, enrollment tokens, Cloudflare account secrets, proxy credentials, actual carrier DNS addresses, root-grant material, or full diagnostic archives.

## Authority rule

```text
Git/GitHub = source, workflow, artifact and evidence authority
runtime owners = current product facts
Cloudflare/Android/carrier = live external reality
logs/metrics/test output = evidence only
```

E4 results never become a second runtime readiness owner.
