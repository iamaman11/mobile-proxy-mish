# System and process model

Canonical product path:

```text
Kameleo / Camoufox
 -> Cloudflare One Client
 -> Cloudflare Mesh
 -> Cloudflare One Agent on Android
 -> product-admitted Mesh listener
 -> sing-box :1080 / :1081 / :3128
 -> product Cellular Egress
 -> validated Android cellular Network
 -> LTE/5G Internet
```

Cloudflare One Agent is the external Android VPN/private-transport owner. The product does not own a second VPN in Mesh mode.

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
root operations             narrow operation-scoped adapter only when proven necessary
```

Logical capabilities are not processes.
