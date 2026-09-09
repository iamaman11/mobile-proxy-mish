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

Cloudflare One Agent is the external Android VPN/private-transport owner. The product does not own a second Android VPN in Mesh mode.

Initial product process topology is deliberately small:

```text
Mobile Proxy Android process
├─ ForegroundService lifecycle anchor (future B2+)
├─ thin Kotlin Android adapter
├─ Rust core / natural-owner crates
├─ Compose UI projection
└─ optional in-process Mesh ingress only if direct binding fails physical proof

sing-box                    separate owned vendor child process (future)
Cloudflare One Agent        external vendor process
Cloudflare One Client       external Windows vendor process
root operations             narrow operation-scoped adapter only when proven necessary
```

Logical capabilities are not processes.
