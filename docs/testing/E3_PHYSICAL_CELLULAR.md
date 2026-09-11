# E3 — physical cellular acceptance

This is the versioned execution protocol for the first physical proof under Issue #10.

E3 proves only the Cellular Egress boundary on a real rooted Android phone with a real carrier. It does **not** prove Cloudflare Mesh end-to-end, sing-box proxy serving, Kameleo/Camoufox, E4, final DNS anti-leak acceptance under Issue #64, or overall product readiness.

The historical RC6 bind-based path is failure evidence only. Physical DEVICE-1 evidence showed `Network.bindSocket(FileDescriptor)` / `android_setsocknetwork` fail with `EPERM` on the target Cloudflare One Agent topology. A future E3 PASS must exercise the replacement PRODUCT-owned root policy-routing adapter on exact immutable PRODUCT bytes; an old bind-based harness cannot satisfy this revised protocol.

## Evidence contract

The accepted semantic owner path is:

```text
Android requestNetwork(CELLULAR + INTERNET + NOT_VPN)
 -> observed CELLULAR + INTERNET + VALIDATED + NOT_VPN
 -> Rust Cellular Egress owner ADMITTED
 -> fresh owner generation/currentness
 -> PRODUCT root policy adapter reconciles intended proxy-egress selection
 -> current direct-cellular routing table is derived + marked route is validated
 -> fail-closed guard remains after the cellular lookup
 -> cellular-owned target DNS + public connection
 -> real Internet response
```

The evidence-backed selector for current development is:

```text
intended proxy/runtime execution UID
 -> owner-matched NEW outbound egress flow
 -> narrow fwmark/mask
 -> RPDB lookup of current direct-cellular table
 -> masked unreachable guard
```

Acceptance proves the semantic properties, not arbitrary shell command spelling. The root-routing mechanism is an adapter to Cellular Egress; it is not a second admission/readiness owner.

Wi-Fi is not a correctness prerequisite for E3. It may remain present/validated, but it cannot satisfy Cellular Egress and cannot preserve target egress when direct cellular disappears.

The physical ceremony is one continuous PRODUCT/controller lifetime:

```text
positive:
  direct cellular validated/non-VPN
  -> owner ADMITTED with fresh generation
  -> root policy reconciled and marked route validated
  -> cellular-owned DNS/public connection
  -> real HTTP/HTTPS response

negative:
  same live PRODUCT/controller
  -> LAB/root disables mobile data through the accepted bounded test primitive
  -> direct cellular lost
  -> owner NOT_ADMITTED
  -> old generation unusable
  -> unreachable protection remains/effectively blocks intended proxy egress
  -> new target DNS/public connection fails closed
  -> no Wi-Fi/default/WARP/VPN substitution

recovery:
  same live PRODUCT/controller remains alive
  -> LAB/root restores mobile data
  -> requestNetwork() reacquires direct cellular
  -> fresh owner generation
  -> current direct-cellular table rediscovered and policy reconciled
  -> cellular-owned DNS/public connection succeeds again
```

`NO_EVIDENCE_ESCALATION`: hosted CI, emulator, compile/link proof, APK assembly, release verification, LAB-only root-policy canaries, or pre-device readiness cannot replace this physical PRODUCT run.

## Required physical lab environment

The physical executor is the accepted isolated Windows LAB:

```text
runs-on: [self-hosted, windows, x64, mobile-proxy-mish-lab]
PowerShell: C:\mish-lab\tools\powershell-7.6.6\pwsh.exe
ADB: C:\mish-lab\tools\android-sdk\platform-tools\adb.exe
```

The Windows LAB is an exact-artifact consumer/evidence executor only. It does not build Android product or instrumentation bytes and does not hold the Android release signing key.

Phone prerequisites for the physical acceptance run:

- exactly one authorized ADB device;
- fixed current target compatibility: Samsung SM-A022G / Android 11 / API 30 / `armeabi-v7a`;
- real SIM/mobile-data service is available;
- the exact verified RC product APK and same-source/same-certificate E3 harness are used;
- PRODUCT has the explicitly granted, capability-scoped root authority required by its production adapter and can exercise the required bounded operations non-interactively after that explicit grant;
- `adb shell su -c id` may authorize LAB mutation/observation, but ADB root does **not** substitute for PRODUCT runtime root authority;
- Cloudflare One Agent is installed and connected as the target-topology coexistence fixture for this replacement-path E3;
- Wi-Fi may be on or off; it is not Cellular Egress authority.

One Agent being connected does not turn E3 into Mesh acceptance. E3 does not require a Windows->Mesh proxy request and must not claim Transport Reachability/E4 from One Agent presence alone.

## Root policy acceptance constraints

The physical run must prove all of the following for the exact PRODUCT mechanism:

```text
validated cellular admission remains semantic authority
root policy state follows owner generation/currentness
only intended proxy/runtime egress is selected
current direct-cellular table is derived from fresh live state
marked route validation succeeds before positive egress is accepted
missing/stale/ambiguous cellular routing remains fail closed
explicit unreachable protection prevents fallthrough to main/default/Wi-Fi/WARP
IPv6 cannot bypass the policy; unsupported/unvalidated IPv6 remains fail closed
apply/reconcile/update/cleanup are deterministic for the exercised lifecycle
loss/recovery does not restore stale authority
```

Do not route the whole PRODUCT UID merely to make E3 pass unless loopback and Mesh-response behavior has separately been proven safe. A dedicated egress helper/identity is also not required by default; introducing one needs separate privilege/lifecycle/isolation evidence under the minimal-layer invariant.

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

### Native GitHub release immutability is mandatory

Repository setting `Enable release immutability` must be enabled **before the RC is published**. E3 accepts only a GitHub Release whose API metadata reports:

```text
immutable=true
```

This is a byte-integrity requirement, not a documentation label. A release that merely says “immutable” in its notes but reports `immutable=false` is rejected.

GitHub native immutable releases lock the published release assets and associated tag against replacement/movement. The setting applies only to future releases. Therefore historical releases published as mutable evidence cannot satisfy the immutable release-selection gate.

For the selected `rc_tag`, the hosted resolver must fail closed unless it can derive and verify exactly one coherent identity chain:

```text
exact Git tag
 -> exact source commit
 -> published native-immutable GitHub RC prerelease
 -> canonical release APK + release manifest
 -> GitHub asset SHA-256
 -> downloaded APK SHA-256
 -> manifest verification
 -> reviewed release-signing certificate trust anchor
 -> exact successful machine-owned Android Release Candidate run
 -> exact e3-harness-<tag> artifact
 -> artifact SHA-256
 -> harness manifest + product/test bytes
 -> test APK SHA-256
```

The resolved tuple is passed as machine-owned job outputs to the physical Windows job. The existing `labctl release resolve/verify` and `e3 verify` commands then independently re-check those identities before installation/execution.

`latest` is never release authority. A mutable, ambiguous, expired, missing, mismatched, unsigned-by-the-reviewed-identity, or multiply-matching release/harness fails closed before physical execution.

## Pre-device mode

`mode=pre-device-dry` is an execution-path readiness proof only. It requires zero ADB devices and emits bounded typed evidence:

```text
PHONE-ON READY
E3_PASS=NO
NO_EVIDENCE_ESCALATION=PASS
```

It never installs APKs and never satisfies #10.

## What the PRODUCT/harness must prove

The physical acceptance run installs the exact already-verified product and instrumentation APKs and runs one continuous lifecycle case.

The positive/recovery portions must prove that the production Cellular Egress path:

1. acquires and observes a direct cellular Android `Network` through the live owner path;
2. admits only `CELLULAR + INTERNET + VALIDATED + NOT_VPN`;
3. creates a fresh owner generation/currentness boundary after acquisition/recovery;
4. obtains the explicitly granted PRODUCT root capability required by the narrow adapter;
5. discovers exactly one current direct-cellular routing target from fresh live state or fails closed on ambiguity;
6. installs/reconciles the PRODUCT-owned selector + fail-closed guard without globally replacing Android routing;
7. validates the marked/direct-cellular route before considering egress usable;
8. performs target DNS/public connection through the admitted cellular-owned path;
9. obtains a real Internet response and transiently classifies carrier egress without persisting the public IP literal;
10. leaves unsupported/unvalidated IPv6 fail closed rather than allowing default-route bypass.

The negative portion must prove, in the same live PRODUCT/controller lifetime, that loss of direct cellular removes admission, invalidates the old generation and blocks new target egress rather than falling back to Wi-Fi/default/WARP/VPN authority.

The recovery portion must prove fresh rediscovery/reconciliation before public egress returns. Reusing a stale route/generation is a failure.

## Workflow/harness compatibility gate

The E3 workflow and instrumentation harness are evidence machinery, not semantic owners. Before any future run can claim E3 PASS, they must be updated to exercise the accepted PRODUCT root-policy mechanism rather than the historical RC6 per-socket bind seam. A successful run of a stale bind-based harness cannot close Issue #10.

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
root-policy semantic result categories
PASS/FAIL boundary
```

The actual carrier public IP is validated transiently on-device and intentionally not persisted. Do not persist IMEI, IMSI, ICCID, SIM serial, phone number, ADB serial, SSID/BSSID, MAC addresses, private network details, actual carrier DNS addresses, account/enrollment tokens, proxy credentials, root-grant material, or signing secrets.

## Acceptance rule for Issue #10

Issue #10 may close only after a successful protected-main physical run against an exact machine-resolved **native-immutable** RC proves the complete continuous:

```text
positive -> negative -> recovery positive
```

with the PRODUCT-owned root policy-routing adapter, fail-closed guard and fresh owner-generation reconciliation described above.

Hosted resolver success, pre-device readiness, LAB-only policy canaries, release publication, an ADB-root-only proof, a stale bind-based harness, or a fresh-process retry is not E3 acceptance.
