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
E1  code / deterministic CI
E2  Android emulator / bounded platform integration
E3  physical rooted Android + real carrier
E4  Windows -> Mesh -> Android -> cellular -> Kameleo/Camoufox
```

`NO_EVIDENCE_ESCALATION`: weaker evidence cannot close a stronger physical claim.

Hosted CI may compile an instrumentation APK and prove native linkage, but that remains E1/E2. E3 exists only after the versioned physical workflow/procedure executes on a real phone and the run is linked to the stage owner.

Managed physical-lab execution must follow:

- `docs/lab/PLAN.md` — single execution path and stage sequence;
- `docs/lab/SECURITY.md` — self-hosted runner/provider/device trust boundary;
- `docs/lab/EVIDENCE.md` — typed/redacted run evidence contract.

Lab evidence is immutable per-run evidence only. It never becomes a mutable runtime readiness owner or a second current-status database.

Versioned execution protocols:

- `docs/testing/E3_PHYSICAL_CELLULAR.md` — real phone/carrier same-network DNS/socket proof and fail-closed cellular-loss ceremony;
- `docs/testing/E4_FULL_STACK.md` — future Windows/Cloudflare/Mesh/sing-box/Kameleo/Camoufox full-stack contract.

External vendor applications are acceptance fixtures, not product artifacts or runtime-state authorities. Their supported boundary behavior is observed; hidden APIs/UI scraping/repackaging are not accepted evidence paths.

Release acceptance later includes cellular-only egress with Wi-Fi simultaneously connected, fail-closed behavior, Mesh-only exposure, the full :1080/:1081/:3128 protocol/auth matrix, rotation crash/reconciliation, reboot/churn/Doze, Kameleo/Camoufox, load, and soak.
