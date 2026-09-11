# System and process model

Canonical product path:

```text
Windows ordinary traffic
 -> sing-box TUN (default/full-tunnel owner)
 -> existing Windows Internet path

Kameleo / Camoufox
 -> configured proxy at Android Mesh IP:proxy port
 -> Windows route for the Mesh/device CIDR
 -> Cloudflare One Client
    Traffic only / TunnelOnly
    MASQUE primary transport
 -> Cloudflare Mesh
 -> Cloudflare One Agent on Android
 -> product-admitted Mesh listener
 -> sing-box :1080 / :1081 / :3128
 -> product Cellular Egress
 -> validated direct-cellular authority
 -> lifecycle-bounded root policy-routing adapter
 -> intended proxy-egress flows use the current direct-cellular routing table
 -> cellular-owned target DNS + public sockets
 -> LTE/5G Internet
```

Windows routing ownership is intentionally split by destination, not by a second default tunnel:

```text
ordinary Internet         -> sing-box TUN
Cloudflare Mesh CIDR      -> CloudflareWARP
Windows DNS               -> existing sing-box/system path
Cloudflare Local Proxy    -> not part of the product dataplane
```

The actual Mesh/device CIDR is provider live state and must be read back before use; the current Cloudflare default range is not persisted as a universal invariant. Cloudflare Split Tunnel is destination-based. Per-application fail-closed enforcement on Windows is a separate security boundary and must not be inferred from Split Tunnel behavior alone.

MASQUE is the primary Cloudflare One transport. Cloudflare One WireGuard may be used only as a bounded fallback after a concrete MASQUE defect is demonstrated; it does not create a separate custom WireGuard mesh/control plane.

## Android VPN and egress ownership

Cloudflare One Agent is the **only Android VPN/VpnService owner** in Mesh mode. The product must not start a second Android TUN/VpnService and sing-box must run only as proxy/server infrastructure on Android.

```text
ANDROID_VPN_OWNER          = Cloudflare One Agent only
SING_BOX_ANDROID_MODE      = proxy/server only; NO TUN; NO VpnService
MESH                       = ingress/private transport only
PUBLIC_PROXY_EGRESS        = product Cellular Egress owner only
PROXY_TARGET_DNS           = cellular-owned path; final resolver/anti-leak acceptance belongs to Issue #64
PUBLIC_PROXY_SOCKETS       = product-owned fail-closed policy routing to the current direct-cellular table
CELLULAR_LOST              = retain/establish unreachable protection; no Wi-Fi/default/WARP fallback
```

Cloudflare One Agent may use Wi-Fi or another available underlay to keep the Mesh transport connected. That underlay does not own proxy Internet egress. A request arriving over Mesh must not be allowed to use Android default routing, system DNS, Wi-Fi egress, or Cloudflare Internet egress for its target connection.

Android `Traffic and DNS` may remain the One Agent operating mode and may own system/application DNS for ordinary Android traffic. MISH proxy target names are intentionally outside that ownership. The Cellular Egress owner remains the semantic authority for whether target DNS/public egress is admitted; the infrastructure mechanism must steer only the intended proxy-egress flow to the live direct-cellular path and fail closed when the authority is missing, stale or ambiguous. Issue #64 owns the final DNS resolver/anti-leak contract and must not become a second Cellular Egress owner.

## Root policy-routing execution boundary

Physical DEVICE-1 evidence under Issue #63 and the B2 disposition in Issue #10 supersede the earlier per-socket bind mechanism for the target Cloudflare One Agent topology:

```text
Network.bindSocket(FileDescriptor) / android_setsocknetwork
 -> EPERM on the target topology

root-owned egress selector
 -> narrow fwmark/mask
 -> RPDB lookup of the current direct-cellular table
 -> masked unreachable guard after the cellular lookup
 -> direct LTE/5G public egress
```

The root policy-routing mechanism is an adapter to the existing Cellular Egress owner, not a new owner or state machine. The owner continues to own admission, generation/currentness and availability. The adapter may observe only the live routing facts needed to realize that decision.

Production rules:

- product root authority must be explicit and capability-scoped; ADB root is test/lab authority and cannot substitute for PRODUCT runtime authority;
- rules must target only intended proxy/runtime egress, not globally replace Android routing;
- do not assume routing the entire PRODUCT UID is safe until loopback and Mesh-response behavior is physically proven;
- the direct-cellular table must be derived from fresh Android/network state and validated before traffic is admitted;
- missing, stale or ambiguous cellular routing keeps/installs fail-closed protection rather than permitting main/default/Wi-Fi/WARP fallback;
- IPv6 must remain fail-closed until a direct-cellular IPv6 path is separately validated;
- apply/update/remove/reconcile must be idempotent and cleanup must touch only exact PRODUCT-owned policy objects;
- lifecycle reconciliation is required after admission/loss, cellular generation change, PRODUCT restart and boot; additional One Agent/reboot behavior remains evidence-gated until directly tested.

The evidence-backed selector for current development is owner-matched narrow fwmark routing. `uidrange` did not carry the tested HTTPS path. A dedicated egress process/identity is **not** justified unless later privilege/lifecycle/isolation evidence proves that the existing owner plus one narrow adapter cannot solve the requirement correctly.

The critical physical seam remains evidence-gated: with One Agent connected and cellular admitted, target DNS/public traffic must produce carrier egress while the Mesh/private transport remains independently available; when cellular is lost, target egress must fail rather than fall back. Configuration or hosted tests cannot prove this boundary.

Initial product process topology is deliberately small:

```text
Mobile Proxy Android process
├─ ForegroundService lifecycle anchor (future B2+)
├─ thin Kotlin Android adapter
├─ Rust core / natural-owner crates
├─ Compose UI projection
└─ root/network execution adapter behind the existing Cellular Egress owner

sing-box                    separate owned vendor child process; proxy/server only on Android
Cloudflare One Agent        external Android VPN/private-transport owner
Cloudflare One Client       external Windows vendor process
```

A new helper/root daemon/process is not part of the default topology. It may be introduced only if a concrete privilege, lifecycle or failure-isolation fact proves that one in-process owner plus one narrow adapter is insufficient.

Logical capabilities are not processes.
