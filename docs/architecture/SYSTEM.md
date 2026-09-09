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
 -> validated Android cellular Network
 -> network-scoped DNS + bind-before-connect
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
PROXY_TARGET_DNS           = exact cellular Network-scoped DNS only
PUBLIC_PROXY_SOCKETS       = bind exact cellular Network before connect
CELLULAR_LOST              = fail closed; no Wi-Fi/default/WARP fallback
```

Cloudflare One Agent may use Wi-Fi or another available underlay to keep the Mesh transport connected. That underlay does not own proxy Internet egress. A request arriving over Mesh must not be allowed to use Android default routing, system DNS, Wi-Fi egress, or Cloudflare Internet egress for its target connection.

Android `Traffic and DNS` may remain the One Agent operating mode and may own system/application DNS for ordinary Android traffic. MISH proxy target names are intentionally outside that DNS ownership: target DNS and target sockets use the same owner-issued exact cellular authority through the existing Android network boundary (`android_getaddrinfofornetwork` / `android_setsocknetwork` semantics).

The critical physical seam remains evidence-gated: with One Agent connected, Wi-Fi present, and cellular admitted, target DNS/socket must produce carrier egress; when cellular is lost while Wi-Fi/Mesh remain available, target connection must fail rather than fall back. This is not inferred from configuration or hosted tests.

Initial product process topology is deliberately small:

```text
Mobile Proxy Android process
├─ ForegroundService lifecycle anchor (future B2+)
├─ thin Kotlin Android adapter
├─ Rust core / natural-owner crates
├─ Compose UI projection
└─ optional in-process Mesh ingress only if direct binding fails physical proof

sing-box                    separate owned vendor child process; proxy/server only on Android
Cloudflare One Agent        external Android VPN/private-transport owner
Cloudflare One Client       external Windows vendor process
root operations             narrow operation-scoped adapter only when proven necessary
```

Logical capabilities are not processes.
