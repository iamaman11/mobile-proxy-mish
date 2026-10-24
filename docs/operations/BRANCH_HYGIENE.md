# Evidence-locked repository branch hygiene (2026-10-25)

This is **repository ref maintenance only**. It does not edit Rust/Kotlin PRODUCT, APKs, DEVICE-1, signing credentials, Windows WARP or Cloudflare.

- Historical snapshot: [branch-inventory-2026-10-25.json](../audits/branch-inventory-2026-10-25.json) contains **398 pre-maintenance heads**, each head SHA, last commit UTC, PR relation, literal-reference scan and KEEP/REVIEW/DELETE_CANDIDATE rationale. It is **not** a live branch-status database.
- Exact reviewed deletion allowlist: [branch-prune-allowlist-2026-10-25.json](../../.github/branch-prune-allowlist-2026-10-25.json). Only **272** exact branch tips with merged PRs targeting `main` qualify. **123** ambiguous or non-main-merged refs remain REVIEW; `main`, `integration/m1`, and `rotation/candidate-a-product` remain KEEP.
- Evidence source: GitHub REST ref enumeration, all **381** historical PRs, exact head commit metadata and literal scan of 53 current workflow/docs/README/AGENTS files. External branch consumers are not knowable; unknown work is retained.

## Exact, explicit owner procedure

Only repository owner `iamaman11` can invoke the canonical [Issue #457](https://github.com/iamaman11/mobile-proxy-mish/issues/457) commands. SHA is the **Git blob SHA of the allowlist contents**, not the GitHub commit SHA:

```text
/mish-maint branches-dry-run d897a78abdba1e630223fbffa250b4408a2601b5
/mish-maint branches-prune d897a78abdba1e630223fbffa250b4408a2601b5
```

The protected-main `branch-hygiene.yml` workflow requires the exact command/issue/owner and verifies the allowlist Git blob hash, inventory consistency and **272 exact entries**. For every candidate it verifies the unchanged head SHA, nonprotected status, exact merged-to-`main` PR head, no new open PR, no active workflow literal dependency and explicit branch exclusions. It fails closed on any unexpected evidence or API failure; no bulk delete by age, filename or mere branch divergence. One attempt has no hidden retries.

Run **dry-run** and inspect its uploaded per-branch receipt first. Only then invoke **prune**. Compare exact deleted counts and fresh remaining branch refs; retain sanitized GitHub Actions receipts and Issue #457 links. Never treat GitHub Actions `success` as proof that all branches were deleted without examining its typed receipt.

No ref deletion is authorized outside the exact current allowlist. The historical inventory must not be reused for a new deletion campaign without fresh ref/PR/dependency evidence. Deleting branches does not delete tags, PR discussions or protected-main history. Current PRODUCT source authority remains Issue #135.
