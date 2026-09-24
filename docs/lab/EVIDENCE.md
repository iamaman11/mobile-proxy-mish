# Managed lab evidence contract

Physical/provider runs produce evidence, not runtime authority. Evidence is immutable per-run output tied to exact identities and must never become a competing mutable readiness/status database.

## Identity model

Development physical evidence keeps control and product identities separate:

```text
PRODUCT_SHA
  exact application source/build identity being exercised

CONTROL_SHA
  exact protected-main workflow/script identity executing the cycle

HOSTED_RUN_ID / artifact id + digest
  exact hosted candidate provenance when bytes are consumed

DEVICE_CYCLE_RUN_ID
  immutable physical execution/evidence identity
```

There is no current RC/prerelease evidence lineage. If a future external-distribution identity is introduced, its exact immutable fields are defined only by `RELEASE.md` and must reuse the existing source/build/physical authority.

A local working-tree path, process PID by itself, branch nickname or “latest” is never durable artifact/product identity.

## Evidence envelope

Evidence schemas are owned by their executable producer. New managed evidence should record the minimum exact provenance needed by its claim. For a development Device Cycle this includes, directly or through immutable linked run metadata:

```json
{
  "product_sha": "<40-hex PRODUCT_SHA>",
  "control_sha": "<40-hex CONTROL_SHA>",
  "hosted_run_id": "<exact producer run when applicable>",
  "device_cycle_run_id": "<exact physical run>",
  "result": "PASS",
  "classification": "PASS",
  "observations": {}
}
```

A host/provider-only run may use a simpler schema because it makes no PRODUCT acceptance claim.

`result` describes only that exact run/request. It is never read by PRODUCT as live current readiness.

## Typed failure

Failures should be typed rather than inferred from free-form logs. Categories are introduced only for a concrete consumer/operator distinction, for example:

```text
HOST_PREREQUISITE_MISSING
UNTRUSTED_REF
IDENTITY_MISMATCH
ARTIFACT_PROVENANCE_MISMATCH
DEVICE_REQUIRED
DEVICE_UNAVAILABLE
DEVICE_INCOMPATIBLE
TEST_FAILED
TIMEOUT
CANCELLED
OBSERVATION_CONTRADICTION
```

Do not build a generic failure taxonomy framework beyond actual consumers.

## Physical observation rules

Observations are facts from natural PRODUCT owners or external fixtures. Do not infer READY/acceptance from package presence, a process name, stale files, a historical successful run or a weaker probe.

For installation claims, record/verify the exact installed APK digest and signing identity before launch acceptance.

For current runtime claims, use current native owner facts (runtime, Cellular, root policy, Proxy Serving, credentials, Mesh, readiness) and the exact functional evidence required by the active roadmap stage.

Historical Android sing-box/runtime files or processes are not current PRODUCT evidence. If they are observed during LAB hygiene, record only the bounded facts needed for cleanup/attribution and never promote them into PRODUCT state.

## Evidence ladder

```text
E1 code / deterministic hosted CI
E2 bounded Android build/platform integration
E3 physical rooted Android + real carrier
E4 Windows -> Mesh -> Android -> cellular -> real external path
```

`NO_EVIDENCE_ESCALATION`: evidence can claim only the domain physically/executably exercised by that exact run.

A development `full` Device Cycle can establish exact stage-specific physical facts when provenance and the required topology are exercised. `diagnose_only` / read-only `probe_only` evidence does not establish exact installed-candidate acceptance unless the corresponding installation identity was independently and explicitly bound by the acceptance contract.

Development debug evidence is not external-distribution identity and cannot be silently relabeled as one.

## Support reconstruction packet

U8 support/provenance closure does not create another evidence producer. When support needs a durable
identity packet, compose existing immutable records:

```text
accepted protected-main SHA
exact PRODUCT_SHA / CONTROL_SHA for the relevant evidence
hosted producer run + artifact id/digest when applicable
Device Cycle run id
installed digest/signing proof when applicable
typed result/classification
smallest relevant typed observations
```

This composition may be written into an issue/checkpoint or referenced directly by immutable GitHub
run/artifact ids. Do not create a mutable support database, duplicate status file, broad environment
dump or second current-stage pointer merely for convenience.

## Secrets and privacy

Evidence must never contain:

- passwords/proxy credential material;
- Cloudflare API/enrollment tokens;
- GitHub runner registration tokens;
- Cloudflare API credentials;
- IMEI, IMSI, ICCID, SIM number or phone number;
- arbitrary environment dumps;
- Android ephemeral Network handles;
- private keys;
- unbounded logs/process dumps;
- full secret-bearing command lines.

When a public IP must be validated, prefer a boolean/type assertion, digest, or changed/unchanged result rather than persisting the literal unless a specific local-only product requirement needs it.

## Storage and live-state rule

Primary durable evidence is the GitHub workflow/check/artifact record for the exact run. Uploaded JSON evidence is immutable bounded run output with appropriate retention.

Do not add a mutable lab status database, D1 table, local registry or second current-stage pointer. Current stage and accepted evidence ids belong to Issue #135. Current runtime facts belong to their PRODUCT/provider/device owners.

## Local-agent evidence

A local agent may collect one bounded missing physical fact when current repository tooling cannot. Its raw local output is not automatically durable authority. Sanitize and record only the necessary conclusion/evidence pointer in GitHub (#135, a stage-specific evidence surface, or the relevant natural-owner contract) before relying on it across context loss.
