# Readiness and acceptance

Runtime readiness is one pure derived projection over fresh owner observations:

```text
READY
NOT_READY
DEGRADED
UNKNOWN
```

Lifecycle is orthogonal. Stale required observations become `UNKNOWN`; `UNKNOWN` never counts as success.

Evidence domains:

```text
E1  code and deterministic hosted CI
E2  bounded Android/platform integration
E3  physical rooted Android plus real carrier acceptance
E4  Windows -> Mesh -> Android -> cellular -> external client full stack
```

`NO_EVIDENCE_ESCALATION`: weaker evidence cannot close a stronger claim.

## Development physical diagnostics

When Issue #135 requires a real-device fact for the next engineering decision, DEVICE-1 may consume an exact-head hosted debug candidate under `docs/architecture/DEVELOPMENT_PIPELINE.md`.

That path must preserve exact source, workflow run, artifact and digest identity, use the isolated debug package, avoid implicit local rebuilding, and keep evidence bounded and sanitized.

A successful development diagnostic proves only the measured physical fact. It is not product release identity and does not authorize release promotion.

## Formal physical and release acceptance

Formal E3/release acceptance remains a stronger boundary and uses exact immutable RC/release bytes under `docs/architecture/RELEASE.md`.

```text
PIN -> BUILD ONCE -> HASH -> SIGN -> ATTEST -> TEST EXACT BYTES -> PROMOTE EXACT BYTES
```

A debug candidate cannot be relabeled as an RC/release.

Managed physical-lab execution must preserve the trust/evidence rules in:

- `docs/lab/PLAN.md`;
- `docs/lab/SECURITY.md`;
- `docs/lab/EVIDENCE.md`;
- `docs/architecture/DEVELOPMENT_PIPELINE.md` for development candidate diagnostics.

Lab evidence is immutable per-run evidence only. It never becomes a mutable runtime readiness owner or a second current-status database.

Versioned physical protocols include:

- `docs/testing/E3_PHYSICAL_CELLULAR.md` — real phone/carrier cellular proof;
- `docs/testing/E4_FULL_STACK.md` — Windows/Cloudflare/Mesh/Android/client full-stack contract.

External vendor applications are acceptance fixtures, not product artifacts or runtime-state authorities.
