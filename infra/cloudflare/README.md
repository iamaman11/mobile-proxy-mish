# Cloudflare integration boundary

This directory contains the two direct Cloudflare integration surfaces used by `mobile-proxy-mish`.

## Mesh / Zero Trust verification

The live Windows/Cloudflare Mesh prerequisites are verified through the official Cloudflare API by:

```text
.github/workflows/cloudflare-live-preflight.yml
```

That workflow is read-only and checks the accepted Windows profile, Mesh CIDR, device TCP/UDP/virtual-IP settings, and WARP-to-WARP connectivity. Cloudflare remains the live configuration authority.

## U8-E control Worker

The authenticated remote-rotation control plane lives under:

```text
infra/cloudflare/control-worker/
```

It is deployed directly with Wrangler and owns only:

- the `mish-device-control` Worker;
- the `DeviceControl` Durable Object binding;
- the control hostname;
- the Worker secret `MISH_MANAGER_TOKEN`.

The Android device authenticates with its non-exportable Keystore P-256 key. Cloudflare stores only the enrolled public SPKI and bounded operation correlation. Proxy credentials are not part of this control plane.

## Boundary

There is no second configuration engine, mutable mirror, offline command queue, Workers VPC dependency, or Android inbound listener. Mesh verification and control-Worker deployment stay independent.
