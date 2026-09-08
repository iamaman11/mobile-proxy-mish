# Mobile Proxy MISH

Clean successor / PoC repository for a VM-free Android mobile proxy using Cloudflare Mesh as private transport while preserving phone-owned LTE/5G egress.

## Current status

**Planning only. No implementation has been accepted yet.**

The canonical planning baseline is:

- #1 — product goal, target architecture candidate, Cloudflare/Android assumptions, complete HTTP + SOCKS5 compatibility requirements, PoC sequence, testing boundaries and unresolved decisions.

Next design work:

- #2 — invariants, natural owners, technology stack, Android process model, security model, release/supply-chain model and measurable DoD.

Reference-only migration material:

- #3 — bounded reusable concepts/files from `iamaman11/mobile-proxy`; not an instruction to copy the predecessor architecture.
- #4 — external/vendor facts that must be re-verified before implementation.

## Working architecture hypothesis

```text
Kameleo / Camoufox
        |
        v
Cloudflare One Client
        |
        v
Cloudflare Mesh
        |
        v
Cloudflare One Agent on Android
        |
        v
Mesh-only ingress
        |
        v
sing-box
  |- :1080 mixed HTTP/SOCKS5
  |- :1081 SOCKS5
  `- :3128 HTTP/CONNECT
        |
        v
cellular-egress owner
        |
        v
Android Network.bindSocket(validated cellular)
        |
        v
LTE/5G Internet
```

No VM/VPS is part of the target design.

## Design rule

Do not copy predecessor frameworks or start implementation before #2 defines the ownership/invariant model. Reuse only bounded proven code whose natural owner still exists in this clean architecture.
