# Managed lab evidence contract

Physical and provider runs produce evidence, not runtime authority. Evidence is immutable per-run output tied to exact identities and may never become a competing mutable readiness database.

## Required envelope

Every managed-lab evidence document must include:

```json
{
  "schema": "mish.lab.evidence/v1",
  "run_kind": "host-preflight",
  "repository": "iamaman11/mobile-proxy-mish",
  "git_ref": "refs/heads/main",
  "git_commit": "<40-hex accepted commit>",
  "started_at_utc": "<RFC3339>",
  "completed_at_utc": "<RFC3339>",
  "result": "PASS",
  "failure": null,
  "observations": {}
}
```

`result` is limited to the acceptance result for that run. It must not be read by the product as live current readiness.

## Typed failure

Failures should be typed rather than inferred from free-form logs. Initial cross-stage categories may include only concrete needs such as:

```text
HOST_PREREQUISITE_MISSING
UNTRUSTED_REF
IDENTITY_MISMATCH
PROVIDER_UNAVAILABLE
DEVICE_REQUIRED
DEVICE_UNAVAILABLE
DEVICE_INCOMPATIBLE
BUILD_FAILED
TEST_FAILED
TIMEOUT
CANCELLED
OBSERVATION_CONTRADICTION
```

Do not create a generic failure taxonomy framework beyond actual consumers. Add categories only when a concrete stage needs a distinct operator action.

## Identity requirements

Evidence must bind to the identities required by the stage, for example:

- exact Git commit/ref;
- APK/native artifact SHA-256;
- pinned sing-box version/checksum when involved;
- non-secret Windows/Android build/version identity;
- Cloudflare client version when supported/observable;
- scenario name and timestamp.

A local working-tree path is never evidence identity.

## Observation rules

Observations are read-only facts from natural owners or external fixtures. Examples:

```json
{
  "host": {
    "os": "Windows",
    "architecture": "x86_64",
    "android_sdk_available": true,
    "rust_toolchain_available": true
  },
  "artifacts": {
    "app_apk_sha256": "...",
    "test_apk_sha256": "..."
  }
}
```

Do not infer READY from package presence, process presence, stale files or a previous successful run.

## Secrets and privacy

Evidence must never contain:

- passwords or proxy credentials;
- Cloudflare API/enrollment tokens;
- GitHub runner registration tokens;
- Terraform/R2 credentials;
- IMEI, IMSI, ICCID, SIM number or phone number;
- arbitrary environment dumps;
- Android ephemeral Network handles;
- private keys;
- full command lines when they may contain secrets.

When a public IP must be validated, prefer a boolean/type assertion such as `valid_public_ip_observed=true` instead of persisting the literal unless the acceptance contract specifically requires the value.

## Evidence ladder

```text
E1 code/deterministic hosted CI
E2 bounded Android build/platform integration
E3 physical rooted Android + real carrier
E4 Windows -> Mesh -> Android -> cellular -> real clients
```

`NO_EVIDENCE_ESCALATION`: an evidence document may only claim the domain physically exercised by that run. Host preflight, provider plan, APK build, arm64 link proof and a device-absent dry run cannot claim E3.

## Storage

Primary durable evidence is the GitHub workflow/check/artifact record associated with the exact run. If JSON evidence is uploaded as an artifact, it is immutable run output and must have bounded retention appropriate to the project.

Do not add a mutable lab status database, D1 table, local registry or second live pointer to summarize these files. Current stage status belongs to the stage Issue; current runtime facts belong to runtime/provider/device owners.
