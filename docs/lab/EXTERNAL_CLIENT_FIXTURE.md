# External Client Fixture — M1 TCP-only contract

D3 defines the external acceptance-client fixture used later by E4. It is not a PRODUCT owner, daemon, VPN, resolver, proxy, or routing component.

## M1 decision

M1 keeps the PRODUCT proxy path TCP-only:

- `:1080` mixed HTTP/SOCKS5 over TCP;
- `:1081` SOCKS5 over TCP;
- `:3128` HTTP + CONNECT over TCP.

SOCKS UDP ASSOCIATE, generic UDP tunneling, QUIC proxying, MASQUE and a second VPN/TUN are out of scope for M1. They may be designed as a later milestone only after the TCP path reaches formal acceptance.

The Android phone's Wi-Fi state is **not** a security invariant. PRODUCT public egress remains governed by the accepted Cellular Egress authority/root-policy path. Turning Wi-Fi off may be useful during diagnosis, but M1 correctness must not depend on it.

The external browser fixture instead prevents browser-originated UDP from bypassing the admitted TCP proxy path. E4 must still prove the network outcome; D3 only freezes the exact client-side controls.

## Pinned fixture verified 2026-09-13

The machine-readable authority is `lab/windows/external-client-fixture.json`.

### Kameleo 5.2.1 — Chroma 152

Vendor public release label: `Chroma 152`, based on Chromium `152.0.7977.54`.

Required launch controls:

```text
argument:   --disable-quic
preference: webrtc.ip_handling_policy = disable_non_proxied_udp
```

Kameleo documents native browser preferences and command-line arguments through `BrowserSettings`. Its current blocked-switch list does not include `--disable-quic`. Chromium upstream defines `disable-quic` as disabling QUIC protocol support.

### Kameleo 5.2.1 — Junglefox 153

Vendor public release label: `Junglefox 153`, based on Firefox `153.0`.

Required preferences:

```text
media.peerconnection.ice.proxy_only = true
network.http.http3.enable = false
```

The first setting is Kameleo's documented WebRTC proxy-only control. The second disables Firefox HTTP/3/QUIC for this acceptance fixture.

### Camoufox v152.0.4-beta.30 / Python package 0.5.6

Required launch controls:

```text
block_webrtc = true
firefox_user_prefs["network.http.http3.enable"] = false
```

Camoufox documents `block_webrtc=True` as the WebRTC-disable toggle and accepts Playwright Firefox launch options. Playwright exposes `firefox_user_prefs` for exact Firefox preference values.

## Source references re-read for D3

Kameleo:

- https://kameleo.io/downloads
- https://kameleo.io/browser-kernel-releases
- https://developer.kameleo.io/tutorials/using-proxy-servers/
- https://developer.kameleo.io/tutorials/passing-command-line-switches/
- https://developer.kameleo.io/reference/blacklisted-browser-switches/

Camoufox / Firefox launch surface:

- https://github.com/daijro/camoufox/releases/tag/v152.0.4-beta.30
- https://camoufox.com/python/usage/
- https://camoufox.com/fingerprint/webrtc/
- https://playwright.dev/python/docs/api/class-browsertype

Upstream transport controls:

- Chromium `disable-quic` switch: `chrome/common/chrome_switches.cc`
- Firefox HTTP/3 preference: `network.http.http3.enable`

## Acceptance boundary

D3 deterministic hosted checks prove only that the pinned fixture contains the required controls and version coordinates. They do **not** prove physical browser packets, Cloudflare Mesh behavior, Android routing, DNS anti-leak behavior, cellular egress, or `PROXY_ON_PHONE_WORKING=YES`.

E4 must run the pinned fixture and demonstrate that no UDP/QUIC path reaches the Internet outside the admitted proxy path. Any later change to a pinned browser/kernel version requires re-reading its current vendor/upstream controls and updating this fixture deliberately.
