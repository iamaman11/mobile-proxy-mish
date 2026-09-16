# System and process model

Canonical product path:

```text
Windows ordinary traffic
 -> sing-box TUN (Windows default/full-tunnel owner)
 -> existing Windows Internet path

Kameleo / Camoufox
 -> configured proxy at Android Mesh IP:proxy port
 -> Windows route for the Mesh/device CIDR
 -> Cloudflare One Client
    Traffic only / TunnelOnly
    MASQUE primary transport
 -> Cloudflare Mesh
 -> Cloudflare One Agent on Android
 -> Rust Transport exact-address Mesh ingress
 -> Rust Proxy Serving :1080 / :1081 / :3128
 -> direct Cellular Egress connector
 -> validated direct-cellular authority
 -> lifecycle-bounded root policy-routing adapter
 -> flow-stable MISH mark/connmark
 -> current direct-cellular routing table
 -> cellular-owned exact-network target DNS + PRODUCT-UID public socket
 -> LTE/5G Internet
```

There is no Android sing-box dataplane and no private loopback Cellular bridge after L8. HTTP CONNECT, SOCKS5, mixed protocol detection, authentication, target preservation and relay are in-process Rust Proxy Serving responsibilities.

Windows routing ownership is intentionally split by destination, not by a second default tunnel:

```text
ordinary Internet         -> Windows sing-box TUN
Cloudflare Mesh CIDR      -> CloudflareWARP
Windows DNS               -> existing Windows sing-box/system path
Cloudflare Local Proxy    -> not part of the product dataplane
```

The actual Mesh/device CIDR is provider live state and must be read back before use; a provider default range is not persisted as a universal invariant. Cloudflare Split Tunnel is destination-based. Per-application fail-closed enforcement on Windows is a separate security boundary and must not be inferred from Split Tunnel behavior alone.

MASQUE is the primary Cloudflare One transport. Cloudflare One WireGuard may be used only as a bounded fallback after a concrete MASQUE defect is demonstrated; it does not create a separate custom WireGuard mesh/control plane.

## Android VPN and egress ownership

Cloudflare One Agent is the **only Android VPN/VpnService owner** in Mesh mode. MISH must not start a second Android TUN/VpnService.

```text
ANDROID_VPN_OWNER          = Cloudflare One Agent only
ANDROID_PROXY_SERVING      = in-process Rust; NO TUN; NO VpnService
MESH                       = ingress/private transport only
PUBLIC_PROXY_EGRESS        = product Cellular Egress owner only
PROXY_TARGET_DNS           = exact-network cellular-owned resolver path only
PUBLIC_PROXY_SOCKETS       = PRODUCT-UID sockets + fail-closed root policy to current cellular table
CELLULAR_LOST              = keep unreachable protection; no Wi-Fi/default/WARP fallback
```

Cloudflare One Agent may use Wi-Fi or another available underlay to keep Mesh transport connected. That underlay never owns proxy Internet egress. A request arriving over Mesh must not use Android default routing, system DNS, Wi-Fi egress or Cloudflare Internet egress for its public target.

Android `Traffic and DNS` may remain the One Agent operating mode and may own system/application DNS for ordinary Android traffic. MISH proxy target names are outside that ownership. Rust Proxy Serving preserves a domain target unresolved until the direct Cellular connector invokes the narrow Android exact-network resolver for the owner-issued current cellular network authority. No default/process resolver fallback exists.

## Native proxy execution boundary

Proxy Serving is one in-process execution owner:

```text
mish-runtime / Tokio
  |- canonical loopback listeners
  |- one bounded external-session budget
  |- owned accept tasks
  |- owned session tasks
  |- bounded blocking protocol/DNS/connect setup
  `- async bidirectional relay
         |
         v
mish-proxy
  protocol / authentication / unresolved target semantics
```

Tokio belongs only to the runtime execution layer. Protocol/domain crates do not own schedulers. Every listener/session task is retained by the runtime owner and is cancelled/drained at the exact runtime-generation boundary; detached long-lived tasks are prohibited.

## Root policy-routing execution boundary

Physical DEVICE-1 evidence under Issue #63 and the B2 disposition in Issue #10 supersede the earlier per-socket bind mechanism for the target Cloudflare One Agent topology:

```text
Network.bindSocket(FileDescriptor) / android_setsocknetwork
 -> EPERM on the target topology
 -> forbidden from the active PRODUCT runtime path

PRODUCT UID OUTPUT
 -> dedicated MISH_EGRESS_V1 chain
 -> loopback explicit RETURN
 -> restore reserved bit from conntrack
 -> NEW public flow: set + save reserved bit
 -> RPDB lookup of the current direct-cellular table
 -> same-mark unreachable guard after the cellular lookup
 -> direct LTE/5G public egress
```

The root policy-routing mechanism is an adapter to the existing Cellular Egress owner, not a new owner or state machine. Rust continues to own admission, generation/currentness and availability. Kotlin realizes only exact typed effects and exposes no arbitrary shell API.

PRODUCT root authority is one process-wide persistent Magisk `su` transport. Authority proof is cached only for the live shell generation. Terminal denial or unanswered interactive grant is terminal for that app process; transient unavailable/incomplete states may use only bounded recovery. Normal replacement install with stable package signer/UID must not manufacture repeated Magisk prompts.

Production rules:

- PRODUCT root authority is explicit and capability-scoped; ADB root is test/lab authority and cannot substitute for PRODUCT runtime authority;
- the semantic admission predicate remains exactly `CELLULAR + INTERNET + VALIDATED + NOT_VPN`;
- before admission, only the fail-closed base may exist; a permitting IPv4 lookup is installed only after the exact owner generation is ADMITTED;
- route table identity is rediscovered and validated for every fresh admitted generation after loss/recovery;
- one masked MISH bit is restored/saved through conntrack so an already-selected proxy flow cannot lose its routing identity and fall through to Android default routing;
- loopback (`127/8`, `::1`) is explicitly excluded before mark restoration;
- inbound Mesh connections do not acquire a MISH connmark because PRODUCT-side replies are ESTABLISHED rather than NEW public egress;
- missing, stale or ambiguous cellular routing retains fail-closed protection rather than permitting main/default/Wi-Fi/WARP fallback;
- loss removes the permitting lookup but retains classification + guard, so both new and already-marked public target flows fail closed;
- IPv6 uses the same flow classification but remains guard-only/fail-closed until direct-cellular IPv6 is separately validated;
- reserved mark/RPDB/chain collisions with foreign or mismatched objects are typed failures; PRODUCT must not delete unknown objects to make its own policy fit;
- apply/update/reconcile/cleanup are idempotent and cleanup touches only exact PRODUCT-owned policy objects, followed by absence verification;
- lifecycle reconciliation is required after admission/loss, cellular generation change, PRODUCT restart and boot;
- every slow root effect is bounded by owner-generation currentness checks before and after the effect.

The detailed contract is versioned in `docs/architecture/CELLULAR_ROOT_POLICY.md`.

`uidrange` did not carry the tested HTTPS path. Whole-UID direct routing broke Mesh reply behavior and remains prohibited. A dedicated helper/root daemon/process is **not** justified unless later privilege/lifecycle/isolation evidence proves that the existing owner plus one narrow adapter cannot solve the requirement correctly.

The critical physical seam remains evidence-gated: with One Agent connected and cellular admitted, target DNS/public traffic must produce carrier egress while Mesh/private transport remains independently available; when cellular is lost, new target traffic and an already-established marked target flow must fail rather than fall back. Hosted tests cannot prove this final boundary.

## Product process topology

The product topology is deliberately small:

```text
Mobile Proxy Android process
├─ ForegroundService lifecycle anchor
├─ thin Kotlin Android/platform adapters
├─ Rust natural-owner crates
├─ mish-runtime Tokio execution owner
├─ Compose UI projection
└─ one typed root/network policy adapter behind Cellular Egress

Cloudflare One Agent        external Android VPN/private-transport owner
Cloudflare One Client       external Windows vendor process
```

After L8, Android PRODUCT contains no compatibility runtime for the deleted external proxy architecture. It does not scan `/proc` for historical proxy children, interpret old sing-box configuration/PID files, publish migration markers, terminate historical processes, or expose migration failure semantics. Historical residue on a development device is LAB hygiene and can never block or authorize PRODUCT startup.

A new helper/root daemon/process is not part of the default topology. It may be introduced only if a concrete privilege, lifecycle or failure-isolation fact proves that one in-process owner plus one narrow adapter is insufficient.

Logical capabilities are not processes.
