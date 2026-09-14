# Local UDP / QUIC extension contract (not enabled)

Status: **local design branch only**. It now contains a unit/integration-tested exact-address UDP
relay primitive, an opaque epoch-bound association registry, a gated cellular UDP connector, and
an authenticated loopback-only SOCKS5 UDP ASSOCIATE bridge. It deliberately does **not** enable
public Mesh UDP, QUIC, WebRTC, Android runtime composition, or a new root rule in the current
PRODUCT configuration.

M1 remains a TCP-only appliance. A UDP packet must fail closed until every requirement below is
implemented and physically accepted together.

## Non-goals

- No wildcard UDP socket (`0.0.0.0` or `::`).
- No unauthenticated raw UDP relay.
- No whole-UID routing, global default replacement, second VPN/TUN, or generic root shell.
- No inference that MASQUE transport support makes MISH UDP-safe.
- No browser QUIC enablement before the MISH and Windows acceptance gates pass.

## Natural owners

| Fact or operation | One owner | Contract |
| --- | --- | --- |
| Current unique exact Mesh IPv4 and admission epoch | `mish-transport::MeshEndpointOwner` | Existing 0/1/>1 address admission. Loss or change creates a fresh epoch. |
| Exact UDP socket lifetime | `mish-transport::MeshUdpIngressRuntime` (new) | Bind one exact admitted IPv4 and close all UDP association state before an epoch is lost or replaced. |
| SOCKS UDP protocol/authentication and association credential | `mish-proxy` / `cellular-egress-bridge` | The local bridge accepts an authenticated TCP SOCKS control connection and pins one loopback UDP peer. A public association issuer/expiry contract is still required. Source address alone is never authentication. |
| Cellular admission, generation and public egress authorization | existing Cellular Egress owner | No independent UDP admission state. |
| Root packet marking / RPDB mutation | `CellularRootPolicy` narrow adapter | Typed UDP extension of the existing MISH identity only after owner admission. |
| Cellular target DNS resolver and resolver anti-leak | #64 DNS owner | UDP must use this resolver decision; no OS/default/WARP resolver fallback. |
| Browser/process selection on Windows | Windows deployment fixture | The selected application must reach the authenticated MISH proxy path. It is not an Android policy fact. |

## Required data plane

```text
Windows application explicitly selected for MISH UDP
  -> authenticated SOCKS5 TCP control connection over exact Mesh TCP ingress
  -> bounded UDP association, keyed by opaque association id and expiry
  -> exact Mesh IPv4:one UDP relay port (no wildcard)
  -> private loopback UDP bridge endpoint
  -> Cellular Egress owner admits current generation
  -> root policy marks only the association's public UDP flows
  -> current direct-cellular table
  -> LTE/5G Internet
```

The reverse path is equally required. Broad RFC1918, VPN-interface, or `100.96.0.0/12` bypasses
are forbidden. The current TCP chain restores only its MISH connmark and marks `NEW` product
flows; observed inbound Mesh replies are `ESTABLISHED` and do not acquire that mark. UDP must not
assume this remains true: a dynamic exact `/32` RETURN is allowed only if a physical UDP counter
and route test proves an outgoing Mesh reply would otherwise be marked. It must be derived from
the Transport admission epoch and removed before any stale endpoint replacement.

## Authentication and abuse controls

The new relay must not forward an arbitrary datagram merely because it arrived through Mesh.

1. TCP SOCKS authentication succeeds first.
2. The proxy owner issues a random opaque association id with an absolute expiry and a single
   current Mesh admission epoch.
3. The UDP relay accepts a datagram only when it has a valid association, source binding, epoch,
   maximum datagram size and replay/expiry checks.
4. The current local bridge applies per-association packet/byte limits before any
   loopback/backend write. A global admission budget remains required before public enablement.
5. Association count, bytes, packets and idle time are bounded. Overflow is dropped, never queued
   unboundedly.
6. Loss of TCP control, proxy child, Mesh endpoint, Cellular admission, root-policy authorization,
   DNS authority, or expiry removes the association and drops later datagrams.

Do not put a long-lived bearer credential in a UDP payload, log, command line, or Windows route.

### Current local primitive and the remaining control-plane boundary

`mish-transport::UdpAssociationRegistry` currently recognizes a fixed binary envelope:

```text
"MUDP" | 16-byte opaque id | 32-byte per-association secret | non-empty UDP payload
```

It is a deliberately narrow local protocol fixture, not a browser-facing protocol. The registry
pins the first exact source socket, redacts credential debug output, expires permits, and clears
all permits when the Mesh epoch is replaced or revoked. The integration test proves that a wrong
secret, second peer, and stale epoch do not reach the loopback backend, while an admitted payload
round-trips.

A browser's native QUIC implementation cannot emit this envelope. Therefore **a Windows companion
or a real SOCKS5 UDP ASSOCIATE control bridge is mandatory** before browser QUIC can be enabled.
That component must obtain a fresh opaque credential from an authenticated TCP control channel;
the credential issuer must use platform secure randomness and must never log or persist the raw
secret. The local registry is not an authorization API and must not be exposed to UI, network
input, or arbitrary shell commands.

## Cellular root-policy extension

The existing MISH chain currently flow-marks all product UID `NEW` flows and has only loopback
returns. The physical UDP packet classification result decides whether a Mesh `/32` return is
needed. UDP support requires a new *typed desired state*, not an ad-hoc command fragment:

```text
MISH UDP desired state = {
  current mesh endpoint /32,
  cellular admitted generation,
  selected MISH mark/mask/priority tuple,
  UDP association bridge readiness
}
```

Apply order, both IPv4 and IPv6:

```text
1. establish unreachable guard for selected MISH mark
2. remove stale cellular lookup and any previously-proven exact Mesh exemption
3. if required by physical UDP classification, install/verify one current Mesh `/32` RETURN
   before mark/CONNMARK rules
4. install/verify exact cellular lookup for current admitted generation
5. publish UDP bridge usable
```

Loss/update order:

```text
1. stop accepting new UDP associations and close existing association state
2. remove cellular lookup (guard remains)
3. remove only the exact prior `/32` exemption, if one was installed, after relay is closed
4. revoke owner/root-policy authorization
```

If a route table, Mesh `/32`, rule identity, or family verification is missing or ambiguous, the
result is `UDP_NOT_READY`; traffic never falls through to Wi-Fi, WARP, default route, or an
unverified IPv6 path.

## DNS

UDP support does not change #64 ownership. Before a UDP association can resolve a domain:

- current cellular DNS authority must be present for the same cellular generation;
- UDP DNS must be marked and verified through cellular, or TCP/DoT/DoH must be explicitly selected
  by #64;
- after cellular loss, DNS and subsequent UDP association packets must fail closed;
- resolver addresses, answers and public addresses are never emitted as durable evidence.

## Windows / browser policy

MISH cannot force a Windows process into Mesh. The Windows fixture must use an explicit proxy or
process-scoped sing-box routing rule. Browser QUIC may be enabled only when that rule covers UDP
and the browser has no alternate direct/WARP/default route.

For Firefox/Camoufox, acceptance requires a runtime—not configuration-only—proof that:

```text
selected browser process -> authenticated UDP association -> exact Mesh -> cellular
wrong/missing auth -> rejected
cellular loss -> QUIC/UDP fails, no TCP/direct fallback counted as UDP success
```

Until then retain `network.http.http3.enable=false` and WebRTC blocking.

## Acceptance matrix required before enabling

| Gate | Required physical evidence |
| --- | --- |
| Exact bind | one exact admitted Mesh IPv4 UDP socket accepts; wildcard bind absent |
| Auth | correct association passes; wrong/missing/expired/replayed association drops |
| Rate limits | per-association/global overflow drops without memory/thread growth |
| Cellular | UDP DNS and public UDP traverse the current direct-cellular generation |
| No fallback | cellular loss blocks new and existing association traffic; no Wi-Fi/WARP/default escape |
| Recovery | fresh cellular + fresh DNS + fresh Mesh epoch require new association; stale state cannot work |
| Mesh loss | listener and associations close before old or unknown address is accepted |
| IPv6 | either verified cellular UDP path, or explicit IPv6 unreachable guard; no dual-stack bypass |
| Windows | selected app's UDP/QUIC has no non-proxied bypass |
| Cleanup | only exact MISH-owned sockets/rules/associations disappear; foreign state is unchanged |

## Implementation slices

1. `mish-proxy` / bridge: authenticated SOCKS UDP ASSOCIATE, loopback-peer pinning, target and
   per-association rate bounds, and unit vectors are implemented locally. Public association
   issuance/expiry and Android exposure remain.
2. `mish-transport`: exact-address UDP runtime and per-association relay with a typed authorizer
   supplied by the proxy owner; no generic raw relay.
3. Android composition: Mesh epoch + proxy association lifecycle only; no second owner.
4. `CellularRootPolicy`: exact dynamic Mesh `/32` return and protocol-aware verification, plus
   IPv6 explicit guard. This needs a dedicated physical collision/reconciliation run.
5. #64 DNS: current-generation resolver selection and anti-leak acceptance.
6. Windows fixture: application-scoped routing and browser QUIC/WebRTC acceptance.

No slice may enable browser QUIC before all preceding slice evidence is complete.
