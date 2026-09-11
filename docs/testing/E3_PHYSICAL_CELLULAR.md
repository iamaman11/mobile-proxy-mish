# E3 — physical cellular acceptance

This is the versioned execution protocol for the first physical proof under Issue #10.

E3 proves only the Cellular Egress boundary on a real rooted Android phone with a real carrier. It does **not** prove Cloudflare Mesh, sing-box proxy serving, Kameleo/Camoufox, E4, DNS anti-leak acceptance, or overall product readiness.

## Evidence contract

The accepted B2 owner path is:

```text
Android requestNetwork(CELLULAR + INTERNET + NOT_VPN)
 -> observed CELLULAR + INTERNET + VALIDATED + NOT_VPN
 -> Rust Cellular Egress owner ADMITTED
 -> owner-issued exact-network lease
 -> network-scoped DNS
 -> same lease binds exact socket
 -> real Internet response
```

Wi-Fi is not a correctness prerequisite. It may remain present/validated, but it cannot satisfy Cellular Egress and cannot preserve admission when direct cellular disappears.

The physical ceremony is one continuous instrumentation lifetime:

```text
positive:
  direct cellular validated/non-VPN
  -> owner ADMITTED
  -> exact-network DNS/socket lease
  -> real HTTP response

negative:
  same live request/controller
  -> LAB/root svc data disable
  -> direct cellular lost
  -> owner NOT_ADMITTED
  -> no new cellular lease
  -> previously issued lease revoked
  -> no Wi-Fi/default/VPN substitution

recovery:
  same live request/controller remains alive
  -> LAB/root svc data enable
  -> requestNetwork() reacquires direct cellular
  -> fresh owner authority / fresh lease
  -> network-scoped DNS/socket
  -> real HTTP response again
```

`NO_EVIDENCE_ESCALATION`: hosted CI, emulator, compile/link proof, APK assembly, release verification, or pre-device readiness cannot replace this physical run.

## Required physical lab environment

The physical executor is the accepted isolated Windows LAB:

```text
runs-on: [self-hosted, windows, x64, mobile-proxy-mish-lab]
PowerShell: C:\mish-lab\tools\powershell-7.6.6\pwsh.exe
ADB: C:\mish-lab\tools\android-sdk\platform-tools\adb.exe
```

The Windows LAB is an exact-artifact consumer/evidence executor only. It does not build Android product or instrumentation bytes and does not hold the Android release signing key.

Phone prerequisites for `full-root-toggle`:

- exactly one authorized ADB device;
- fixed target compatibility: Samsung SM-A022G / Android 11 / API 30 / `armeabi-v7a`;
- `adb shell su -c id` proves root;
- real SIM/mobile-data service is available;
- the exact verified RC product APK and same-source/same-certificate E3 harness are used;
- Wi-Fi may be on or off; it is not Cellular Egress authority.

Cloudflare One Agent is not required to satisfy B2 E3. If it is installed or active, its VPN/private-transport network cannot satisfy the `NOT_VPN` Cellular Egress owner contract and this run still does not become Mesh evidence.

## Exact RC selection — operator input is only the tag

Run only from accepted protected `main`:

```text
Actions -> E3 Physical Cellular -> Run workflow
branch/ref -> main
```

Manual inputs are intentionally minimal:

```text
rc_tag = exact immutable vMAJOR.MINOR.PATCH-rc.N
mode   = pre-device-dry | full-root-toggle
```

There are no human-entered source SHA, APK SHA-256, harness run ID, artifact ID, harness ZIP digest, or test-APK digest inputs.

For the selected `rc_tag`, the hosted resolver must fail closed unless it can derive and verify exactly one coherent identity chain:

```text
exact Git tag
 -> exact source commit
 -> published immutable GitHub RC prerelease
 -> canonical release APK + release manifest
 -> GitHub asset SHA-256
 -> manifest verification
 -> reviewed release-signing certificate trust anchor
 -> exact successful machine-owned Android Release Candidate run
 -> exact e3-harness-<tag> artifact
 -> artifact SHA-256
 -> harness manifest + product/test bytes
 -> test APK SHA-256
```

The resolved tuple is passed as machine-owned job outputs to the physical Windows job. The existing `labctl release resolve/verify` and `e3 verify` commands then independently re-check those identities before installation/execution.

`latest` is never release authority. An ambiguous, expired, missing, mismatched, unsigned-by-the-reviewed-identity, or multiply-matching release/harness fails closed before physical execution.

## Pre-device mode

`mode=pre-device-dry` is an execution-path readiness proof only. It requires zero ADB devices and emits bounded typed evidence:

```text
PHONE-ON READY
E3_PASS=NO
NO_EVIDENCE_ESCALATION=PASS
```

It never installs APKs and never satisfies #10.

## What the instrumentation proves

`mode=full-root-toggle` installs the exact already-verified product and instrumentation APKs and runs one continuous lifecycle case.

The positive/recovery portions prove that the production Rust/UniFFI cellular boundary:

1. acquires a direct cellular Android `Network` through the live `requestNetwork()` owner;
2. admits only `CELLULAR + INTERNET + VALIDATED + NOT_VPN`;
3. mints an opaque `CellularNetworkLease` only while that authority is current;
4. resolves the test hostname through the exact admitted network (`android_getaddrinfofornetwork`);
5. creates a real TCP socket and binds that exact fd through the same lease (`android_setsocknetwork`);
6. connects only to a numeric address returned by network-scoped DNS;
7. performs a bounded real HTTP request;
8. validates that a public IP literal was observed, without persisting the literal.

The negative portion proves, in the same live controller/request lifetime, that loss of direct cellular removes admission, prevents a new lease, and revokes the old lease rather than falling back to Wi-Fi/default/VPN authority.

## Evidence identity and privacy

The workflow summary/evidence may record only bounded non-secret identity such as:

```text
protected-main run identity
exact RC tag/source
verified Android ABI
product APK SHA-256
reviewed signing-certificate SHA-256
harness run/artifact IDs
harness artifact SHA-256
test APK SHA-256
instrumentation identity
PASS/FAIL boundary
```

The actual carrier public IP is validated transiently on-device and intentionally not persisted. Do not persist IMEI, IMSI, ICCID, SIM serial, phone number, ADB serial, SSID/BSSID, MAC addresses, private network details, account/enrollment tokens, proxy credentials, or signing secrets.

## Acceptance rule for Issue #10

Issue #10 may close only after a successful protected-main `mode=full-root-toggle` run against an exact machine-resolved immutable RC proves the complete continuous:

```text
positive -> negative -> recovery positive
```

Hosted resolver success, pre-device readiness, release publication, or a fresh-process retry is not E3 acceptance.
