# E3 — physical cellular acceptance

This is the versioned execution protocol for the first physical proof under Issue #10.

E3 proves only the Cellular Egress boundary on a real rooted Android phone with a real carrier. It does **not** prove Cloudflare Mesh, sing-box proxy serving, Kameleo/Camoufox, E4, or overall product readiness.

## Evidence contract

```text
real Android phone
+ validated Wi-Fi connected
+ real SIM / LTE/5G
+ MISH exact-network owner lease

positive:
validated cellular -> owner ADMITTED
owner lease -> network-scoped DNS
same lease -> exact socket bind
bound socket -> Internet
IP echo -> valid public IP literal observed on-device

negative:
Wi-Fi remains validated
validated cellular absent
owner cannot mint cellular lease
no Wi-Fi/default authority substitution

recovery:
cellular enabled again
fresh cellular observation -> new owner authority
positive proof succeeds again
```

`NO_EVIDENCE_ESCALATION`: successful hosted CI, emulator, arm64 linking, or APK assembly cannot replace this run.

## Required lab environment

The GitHub runner is intentionally external to the product runtime.

Minimum runner labels:

```text
self-hosted
linux
mobile-proxy-mish-e3
```

Runner prerequisites:

- `adb` available in `PATH`;
- Android SDK command-line tools configured through `ANDROID_SDK_ROOT` or `ANDROID_HOME`;
- `rustup`/`cargo` available;
- USB access to the target phone;
- the target phone has authorized USB debugging;
- for `full-root-toggle`, `adb shell su -c id` must yield root;
- Android API level is at least 23;
- the phone ABI is `arm64-v8a` for the current support envelope;
- Wi-Fi is connected to a validated Internet network before the workflow starts;
- a real SIM/mobile-data subscription is available.

Cloudflare One Agent is **not required** for B2 E3. If it happens to be installed, that does not turn this run into Transport/Mesh evidence.

## GitHub workflow

Run the workflow only from accepted `main`:

```text
Actions -> E3 Physical Cellular -> Run workflow
branch/ref -> main
```

The workflow itself rejects a non-`main` ref so a feature-branch run cannot be mistaken for accepted E3 evidence.

Inputs:

- `device_serial`: exact `adb devices` serial;
- `scenario`:
  - `full-root-toggle` — preferred; workflow performs positive -> disable mobile data -> negative -> enable -> positive recovery;
  - `positive-only` — useful when radio mutation is managed manually;
  - `negative-only` — phone must already have cellular data unavailable while validated Wi-Fi remains connected;
- `e3_host`, `e3_port`, `e3_path`: a plain-HTTP endpoint that returns the caller public IP as a bare response body.

Default endpoint is `checkip.amazonaws.com:80/`. The endpoint is a test fixture, not a product dependency and not a readiness authority.

The serial/host/path inputs intentionally accept narrow safe character sets because workflow inputs cross the local `adb` / remote-shell boundary.

## What the instrumentation test actually proves

The target APK contains the same production Rust/UniFFI cellular boundary as the app. The instrumentation APK is only an acceptance driver.

For the positive case it:

1. requires a validated Wi-Fi network to be present at the same time;
2. requires a validated cellular network to be present;
3. feeds real Android `NetworkCallback` observations to a fresh Rust `CellularController`;
4. waits for owner `ADMITTED`;
5. requests an opaque `CellularNetworkLease` from the owner;
6. performs `resolveHost()` through that lease (`android_getaddrinfofornetwork`);
7. creates a real TCP socket;
8. binds that exact fd through the same lease (`android_setsocknetwork`);
9. connects to a numeric address returned by the lease-scoped DNS result;
10. makes a bounded plain-HTTP request and validates that the response body is an IPv4/IPv6 literal.

No Java/Kotlin default DNS lookup is used for the destination address: the numeric result is converted with `Os.inet_pton`.

For the negative case it requires validated Wi-Fi to remain present while validated cellular is absent and verifies that the Rust owner cannot become `ADMITTED` or issue a cellular authority lease.

## Evidence identity

The workflow records in the GitHub Actions job summary:

```text
Git commit + refs/heads/main
scenario
non-secret device model
Android version/API
Android build fingerprint
ABI
app APK SHA-256
test APK SHA-256
test echo endpoint
PASS/FAIL
```

The actual carrier public-IP value is validated on-device but intentionally not persisted to public GitHub workflow logs/summary. A failure diagnostic also redacts a `public_ip=` evidence token before printing.

Do not add IMEI, IMSI, SIM number, account credentials, proxy credentials, Cloudflare tokens, or other secrets to evidence.

## Acceptance rule for Issue #10

Issue #10 may close only when a successful E3 run is linked in the issue and the run corresponds to an accepted `main` commit.

A passing `positive-only` run is not enough for the fail-closed portion. Preferred final B2 evidence is `full-root-toggle`; alternatively record separate accepted positive and negative physical runs plus a recovery run when the device cannot use `svc data` reliably.
