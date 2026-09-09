# Cloudflare IaC boundary

This directory is the repository-owned desired-configuration path for the bounded Cloudflare Zero Trust/Mesh configuration used by `mobile-proxy-mish`.

It does **not** make Terraform the live runtime authority. Cloudflare remains the provider authority; Terraform state is deployment machinery only.

## Accepted Windows contract

```text
ordinary Windows Internet -> sing-box TUN
Mesh/device CIDR           -> Cloudflare One Traffic only / TunnelOnly
primary Cloudflare tunnel  -> MASQUE
Windows DNS                -> existing sing-box/system path
Cloudflare Local Proxy     -> not product dataplane
```

The current account-verified Mesh/device range is `100.96.0.0/12`.

## Managed resource

CF-1 adopts the already-existing Windows custom device profile named `adds` as:

```text
cloudflare_zero_trust_device_custom_profile.adds
```

Do not create a duplicate profile. The profile must be imported into the dedicated remote Terraform state before any apply.

The profile match expression is intentionally supplied as a sensitive runtime variable rather than committed to this public repository.

## Read-only account assertions

Provider 5.24.0 exposes `cloudflare_zero_trust_device_settings` as a real data source. CF-1 therefore reads and asserts the existing account-wide facts for:

- unique WARP/device IP assignment;
- Gateway TCP proxy;
- Gateway UDP proxy.

Cloudflare's official API also exposes the Zero Trust connectivity settings used by Mesh:

```text
GET /accounts/{account_id}/zerotrust/connectivity_settings
```

The protected accepted-main provider-plan workflow uses that official read-only API surface to assert:

- WARP-to-WARP/off-ramp connectivity (`offramp_warp_enabled`);
- ICMP proxy (`icmp_proxy_enabled`).

If either fact is disabled or cannot be read successfully, the workflow fails closed before provider planning. It emits only normalized ENABLED/failed status, not the raw account response.

The generated Cloudflare Terraform documentation describes `cloudflare_zero_trust_connectivity_settings`, but the released provider 5.24.0 plugin schema does **not** register that data source. Credential-free CI proved this directly during `terraform validate`. Therefore CF-1 does not fake this observation through a write-capable Terraform resource, custom provider, `local-exec` PATCH, or parallel mutable control path.

When a later released provider actually exposes a working native read/write surface, adoption must happen through an ordinary reviewed provider-upgrade PR.

## Provider and Terraform versions

```text
Terraform             = 1.16.2
cloudflare/cloudflare  = 5.24.0
```

These are exact pins for CF-1. Upgrades require an ordinary reviewed PR.

`infra/cloudflare/.terraform.lock.hcl` is committed dependency-integrity metadata. Its Cloudflare 5.24.0 release hashes are derived from the signed provider release metadata and its Linux/Windows package hashes are re-materialized by `terraform providers lock` in CI. State, backend runtime files and tfvars remain excluded from Git.

## Remote state bootstrap

The CF-1 external bootstrap is materialized:

```text
R2 bucket             = mobile-proxy-mish-terraform-state
R2 credential scope   = that bucket only, Object Read & Write
hosted environment    = cloudflare-plan
```

Existing application buckets must **not** be reused for Terraform state.

The R2 credentials and Cloudflare provider inputs are stored outside Git in the protected hosted secret/vault boundary. Backend configuration is generated temporarily from `backend.r2.hcl.example`; credential values are never written into that file or committed.

The remaining state-bootstrap action is the one-time adoption of the existing `adds` profile into this dedicated remote state.

Never place R2 access keys, Cloudflare API tokens, backend credentials, account-specific profile match expressions, or local backend files in Git.

## Existing profile adoption

The existing `adds` profile is imported once; import changes Terraform state only and must not mutate the Cloudflare profile.

From an accepted `main` checkout with the remote backend initialized and the required provider credentials available:

```bash
terraform -chdir=infra/cloudflare import \
  cloudflare_zero_trust_device_custom_profile.adds \
  "$CLOUDFLARE_ACCOUNT_ID/$CLOUDFLARE_ADDS_POLICY_ID"
```

`CLOUDFLARE_ADDS_POLICY_ID` is a transient runtime value resolved read-only from the existing Cloudflare `adds` profile. It is not a canonical project secret and does not need to be stored in GitHub or the vault after adoption.

After successful import, stop the adoption action. The normal provider plan is a separate accepted-main step through `.github/workflows/cloudflare-terraform-plan.yml`.

If the later plan proposes any unexpected provider change, **do not apply**. Fix the desired configuration in a new PR and repeat from accepted `main`.

The provider-plan workflow is manual, main-only, serialized, and uses the protected `cloudflare-plan` environment. It intentionally refuses to plan until the existing `adds` resource has first been adopted into remote state. It also validates the official connectivity-settings API invariants before the provider plan.

## Canonical external inputs

The project/vault/GitHub Environment names are the canonical names. Operators and agents should look up these names, not Terraform or S3 compatibility aliases:

```text
CLOUDFLARE_ACCOUNT_ID
CLOUDFLARE_WINDOWS_PROFILE_MATCH
CLOUDFLARE_API_TOKEN
R2_STATE_BUCKET
R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY
```

For the hosted `cloudflare-plan` GitHub Environment these map to:

```text
vars.CLOUDFLARE_ACCOUNT_ID
vars.R2_STATE_BUCKET
secrets.CLOUDFLARE_WINDOWS_PROFILE_MATCH
secrets.CLOUDFLARE_API_TOKEN
secrets.R2_ACCESS_KEY_ID
secrets.R2_SECRET_ACCESS_KEY
```

No canonical project secret is named `TF_VAR_cloudflare_account_id`, `TF_VAR_windows_profile_match`, `AWS_ACCESS_KEY_ID`, or `AWS_SECRET_ACCESS_KEY`.

## Process-only Terraform and R2 aliases

Immediately before invoking Terraform, the canonical values are exposed to the process under the names expected by Terraform and its S3-compatible backend:

```text
TF_VAR_cloudflare_account_id  <- CLOUDFLARE_ACCOUNT_ID
TF_VAR_windows_profile_match  <- CLOUDFLARE_WINDOWS_PROFILE_MATCH
AWS_ACCESS_KEY_ID             <- R2_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY         <- R2_SECRET_ACCESS_KEY
```

`TF_VAR_*` is Terraform's standard environment-variable convention for input variables.

`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are **process compatibility names only** used by Terraform's standard `backend "s3"` implementation to authenticate to Cloudflare R2's S3-compatible endpoint. The values are Cloudflare R2 credentials. This project does **not** use an AWS account, AWS S3 bucket, or AWS runtime service for this state path.

The R2 endpoint remains Cloudflare-owned:

```text
https://<CLOUDFLARE_ACCOUNT_ID>.r2.cloudflarestorage.com
```

These aliases are ephemeral process environment variables. Do not create duplicate vault/GitHub secrets under the alias names.

No equivalent provider/R2 secret belongs on the physical Windows runner.

## Credential boundaries

```text
PR head
  -> terraform fmt/lock/init -backend=false/validate only
  -> NO Cloudflare token
  -> NO R2 credentials

accepted protected main
  -> official Cloudflare read-only connectivity assertion
  -> credentialed hosted provider plan/read-back
  -> remote R2 state

protected/manual accepted main
  -> explicit apply only after reviewed plan

physical Windows runner
  -> NO Cloudflare provider token
  -> NO R2 state credentials
```

The current Cloudflare provider documents `Zero Trust Write` for the custom-profile resource. If the currently configured `Zero Trust Read` token cannot perform a required import/refresh/read operation, fail closed and record the exact permission error. Do not widen permissions implicitly. Any permission change is a separate explicit disposition and does not authorize apply.

The official connectivity-settings GET itself requires only read authority. Apply remains a separate protected operation.

## Forbidden shortcuts

- no provider credentials on pull-request heads;
- no local mutable Cloudflare mirror database;
- no dashboard/MCP write path left as a permanent peer of Terraform;
- no custom provider or `local-exec` API mutation to compensate for provider schema gaps;
- no duplicate `adds` profile;
- no reuse of application R2 buckets for Terraform state;
- no duplicate vault/GitHub secrets under Terraform/S3 process-alias names;
- no AWS account/service introduced for the R2 backend;
- no provider/R2 credentials on the physical lab runner;
- no Android, Mesh TCP, E3 or E4 acceptance claim from this IaC stage.
