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
 -> private loopback Cellular Egress bridge
 -> product Cellular Egress
 -> validated direct-cellular authority
 -> lifecycle-bounded root policy-routing adapter
 -> flow-stable MISH mark/connmark
 -> current direct-cellular routing table
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
PUBLIC_PROXY_SOCKETS       = PRODUCT-UID sockets + fail-closed root policy to current direct-cellular table
CELLULAR_LOST              = retain unreachable protection for new + marked established flows; no Wi-Fi/default/WARP fallback
```

Cloudflare One Agent may use Wi-Fi or another available underlay to keep the Mesh transport connected. That underlay does not own proxy Internet egress. A request arriving over Mesh must not be allowed to use Android default routing, system DNS, Wi-Fi egress, or Cloudflare Internet egress for its target connection.

Android `Traffic and DNS` may remain the One Agent operating mode and may own system/application DNS for ordinary Android traffic. MISH proxy target names are intentionally outside that ownership. The Cellular Egress owner remains the semantic authority for whether target DNS/public egress is admitted. Until #64 finalizes resolver/anti-leak behavior, the private loopback bridge may use the narrow read-only Android network-scoped resolver for the exact owner authority; this is transitional infrastructure, not another admission owner.

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

The root policy-routing mechanism is an adapter to the existing Cellular Egress owner, not a new owner or state machine. The Rust owner continues to own admission, generation/currentness and availability. Kotlin realizes only the exact current owner decision and exposes no arbitrary shell API.

Production rules:

- PRODUCT root authority must be explicit and capability-scoped; ADB root is test/lab authority and cannot substitute for PRODUCT runtime authority;
- the semantic admission predicate remains exactly `CELLULAR + INTERNET + VALIDATED + NOT_VPN`;
- before admission, only the fail-closed base may exist; a permitting IPv4 lookup is installed only after the exact owner generation is ADMITTED;
- route table identity is rediscovered and validated for every fresh admitted generation after loss/recovery;
- one masked MISH bit is restored/saved through conntrack so an already-selected proxy flow cannot lose its routing identity and fall through to Android default routing;
- loopback (`127/8`, `::1`) is explicitly excluded before mark restoration;
- inbound Mesh connections do not acquire a MISH connmark because their PRODUCT-side replies are ESTABLISHED rather than NEW public egress;
- missing, stale or ambiguous cellular routing retains fail-closed protection rather than permitting main/default/Wi-Fi/WARP fallback;
- loss removes the permitting lookup but retains classification + guard, so both new and already-marked proxy flows fail closed;
- IPv6 uses the same flow classification but remains guard-only/fail-closed until direct-cellular IPv6 is separately validated;
- reserved mark/RPDB/chain collisions with foreign or mismatched objects are typed failures; PRODUCT must not delete unknown objects to make its own policy fit;
- apply/update/reconcile/cleanup are idempotent and cleanup touches only exact PRODUCT-owned policy objects, followed by absence verification;
- lifecycle reconciliation is required after admission/loss, cellular generation change, PRODUCT restart and boot;
- every slow root effect is bounded by owner-generation currentness checks before and after the effect.

The detailed concrete contract is versioned in `docs/architecture/CELLULAR_ROOT_POLICY.md`.

`uidrange` did not carry the tested HTTPS path. Whole-UID direct routing broke Mesh reply behavior and remains prohibited. A dedicated helper/root daemon/process is **not** justified unless later privilege/lifecycle/isolation evidence proves that the existing owner plus one narrow adapter cannot solve the requirement correctly.

The critical physical seam remains evidence-gated: with One Agent connected and cellular admitted, target DNS/public traffic must produce carrier egress while Mesh/private transport remains independently available; when cellular is lost, new target traffic and an already-established marked target flow must fail rather than fall back. Configuration or hosted tests cannot prove this boundary.

Initial product process topology is deliberately small:

```text
Mobile Proxy Android process
├─ ForegroundService lifecycle anchor (future B2+)
├─ thin Kotlin Android adapter
├─ Rust core / natural-owner crates
├─ Compose UI projection
└─ one typed root/network policy adapter behind Cellular Egress

sing-box                    separate owned vendor child process; proxy/server only on Android
Cloudflare One Agent        external Android VPN/private-transport owner
Cloudflare One Client       external Windows vendor process
```

A new helper/root daemon/process is not part of the default topology. It may be introduced only if a concrete privilege, lifecycle or failure-isolation fact proves that one in-process owner plus one narrow adapter is insufficient.

Logical capabilities are not processes.
