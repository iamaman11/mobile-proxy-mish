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

B1 proves only bootstrap E1/build obligations. It does not claim E3/E4 or product readiness.

Release acceptance later includes cellular-only egress with Wi-Fi simultaneously connected, fail-closed behavior, Mesh-only exposure, the full :1080/:1081/:3128 protocol/auth matrix, rotation crash/reconciliation, reboot/churn/Doze, Kameleo/Camoufox, load, and soak.
