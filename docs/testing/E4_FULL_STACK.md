# E4 — full external stack acceptance (future execution contract)

E4 is the first evidence domain that proves the intended product path end to end:

```text
Windows client
  -> Cloudflare One Client
  -> Cloudflare Mesh
  -> Cloudflare One Agent on Android
  -> product-admitted Mesh ingress
  -> sing-box (:1080 / :1081 / :3128)
  -> Cellular Egress owner
  -> exact cellular DNS/socket path
  -> LTE/5G Internet
  -> Kameleo / Camoufox compatibility
```

This document is intentionally an execution contract only. The E4 workflow must not be enabled as an acceptance gate until Proxy Serving and Transport Reachability are implemented. Creating a fake checker earlier would violate `NO_EVIDENCE_ESCALATION`.

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
actual browser-visible public IP
```

## Recommended physical lab topology

```text
GitHub
  -> protected manual/release workflow
  -> self-hosted Windows acceptance runner
       |- Cloudflare One Client
       |- Kameleo
       |- Camoufox
       `- ADB access to physical Android phone
            |- MISH exact accepted artifact
            |- Cloudflare One Agent
            `- real SIM / LTE/5G + Wi-Fi as required by scenario
```

A separate Linux E3 runner is acceptable. E4 may later use a Windows runner because the real external client applications are Windows-side fixtures.

## Required E4 scenario matrix

At minimum, the future workflow must prove:

```text
Mesh reachability
  Windows -> admitted phone Mesh endpoint

proxy protocol/auth
  :1080 mixed HTTP/SOCKS5
  :1081 SOCKS5
  :3128 HTTP + HTTPS CONNECT
  correct credentials accepted
  wrong/missing credentials rejected

cellular-only egress
  Wi-Fi connected simultaneously
  browser/proxy-visible public IP is carrier egress
  cellular loss does not silently continue over Wi-Fi/default/WARP

real clients
  Kameleo launch/navigation through supported proxy mode
  Camoufox launch/navigation through supported proxy mode

recovery
  One Agent/Mesh reconnect
  cellular reconnect
  product does not restore stale READY
```

Load/soak, reboot, rotation and longer recovery scenarios remain later release evidence as defined by A12.

## GitHub evidence identity

Every E4 run must bind evidence to exact identities:

```text
Git commit / accepted artifact digest
MISH APK/native artifact digest
sing-box version + checksum
Android device model/build (non-secret)
Cloudflare One Agent version where supported
Cloudflare One Client version where supported
Kameleo version
Camoufox version
scenario/timestamp
PASS/FAIL + typed failure reason
```

Never record IMEI, IMSI, SIM identifiers, passwords, enrollment tokens, Cloudflare account secrets, or proxy credentials.

## Authority rule

```text
Git/GitHub = source, workflow, artifact and evidence authority
runtime owners = current product facts
Cloudflare/Android/carrier = live external reality
logs/metrics/test output = evidence only
```

E4 results never become a second runtime readiness owner.
