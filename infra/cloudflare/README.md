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

Do not create a duplicate profile. The existing profile must be adopted into the dedicated remote Terraform state before any provider plan or apply.

The profile match expression is intentionally supplied as a protected runtime secret rather than committed to this public repository.

## Provider and Terraform versions

```text
Terraform             = 1.16.2
cloudflare/cloudflare  = 5.24.0
```

These are exact pins for CF-1. Upgrades require an ordinary reviewed PR.

`infra/cloudflare/.terraform.lock.hcl` is committed dependency-integrity metadata. State, backend runtime files and tfvars remain excluded from Git.

## Remote state and protected execution boundary

The CF-1 external bootstrap is materialized:

```text
R2 bucket             = mobile-proxy-mish-terraform-state
R2 credential scope   = that bucket only, Object Read & Write
hosted environment    = cloudflare-plan
```

Existing application buckets must **not** be reused for Terraform state.

For CF-1 state adoption and provider planning, the protected GitHub Environment `cloudflare-plan` is the execution-time credential source. A local protected vault is **not required** for this procedure and must not be maintained as a duplicate credential store solely for CF-1.

No provider or R2 credential belongs on the physical Windows runner.

## Canonical protected inputs

The protected `cloudflare-plan` GitHub Environment contains the canonical values under these names:

```text
vars.CLOUDFLARE_ACCOUNT_ID
vars.R2_STATE_BUCKET
secrets.CLOUDFLARE_WINDOWS_PROFILE_MATCH
secrets.CLOUDFLARE_API_TOKEN
secrets.R2_ACCESS_KEY_ID
secrets.R2_SECRET_ACCESS_KEY
```

The corresponding project names are:

```text
CLOUDFLARE_ACCOUNT_ID
CLOUDFLARE_WINDOWS_PROFILE_MATCH
CLOUDFLARE_API_TOKEN
R2_STATE_BUCKET
R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY
```

No canonical project secret is named `TF_VAR_cloudflare_account_id`, `TF_VAR_windows_profile_match`, `AWS_ACCESS_KEY_ID`, or `AWS_SECRET_ACCESS_KEY`.

The hosted workflow exposes the canonical values only to its process under the compatibility names expected by Terraform and the standard S3 backend:

```text
TF_VAR_cloudflare_account_id  <- CLOUDFLARE_ACCOUNT_ID
TF_VAR_windows_profile_match  <- CLOUDFLARE_WINDOWS_PROFILE_MATCH
AWS_ACCESS_KEY_ID             <- R2_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY         <- R2_SECRET_ACCESS_KEY
```

`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are process compatibility names only. Their values are Cloudflare R2 credentials used against Cloudflare R2's S3-compatible endpoint:

```text
https://<CLOUDFLARE_ACCOUNT_ID>.r2.cloudflarestorage.com
```

This project does **not** use an AWS account, AWS S3 bucket, or AWS runtime service for this state path.

## One standard operator procedure

`.github/workflows/cloudflare-terraform-plan.yml` is the single protected hosted procedure for CF-1 Terraform state operations and provider planning.

It is:

```text
manual only
accepted-main only
GitHub-hosted only
protected by environment cloudflare-plan
serialized by cloudflare-terraform-provider-state
pinned to Terraform 1.16.2
NO apply path
```

The workflow has two explicit operations:

```text
adopt
plan
```

They are intentionally separate bounded actions.

### Operation: adopt

Dispatch the workflow from accepted `main` with:

```text
operation = adopt
```

The workflow:

1. verifies it is executing the exact current `main`;
2. installs and verifies Terraform 1.16.2 on the ephemeral GitHub-hosted runner;
3. validates all six protected GitHub Environment inputs without printing their values;
4. initializes the dedicated R2 backend at:

   ```text
   bucket = mobile-proxy-mish-terraform-state
   key    = mobile-proxy-mish/cloudflare/terraform.tfstate
   ```

5. checks whether `cloudflare_zero_trust_device_custom_profile.adds` is already in state;
6. if absent, uses the official read-only Cloudflare endpoint:

   ```text
   GET /accounts/{account_id}/devices/policies
   ```

7. requires exactly one non-default profile whose:

   ```text
   name  == adds
   match == protected CLOUDFLARE_WINDOWS_PROFILE_MATCH
   ```

8. treats its `policy_id` as ephemeral masked runtime data;
9. executes only:

   ```text
   terraform import
   ```

10. verifies the resource is present in remote state and stops.

`adopt` does **not** execute Terraform plan or apply and does not create/update/delete the Cloudflare profile. The only intended mutation is Terraform machinery state in the dedicated R2 bucket.

If the profile is already in state, `adopt` exits successfully without re-importing it.

If discovery is ambiguous, the API response is incomplete/paginated beyond the bounded request, the protected inputs are absent, R2 initialization fails, or provider import authority is insufficient, the workflow fails closed. Do not widen Cloudflare permissions implicitly.

### Operation: plan

Only after successful adoption, dispatch the same workflow again from accepted `main` with:

```text
operation = plan
```

The workflow then:

1. initializes the same dedicated R2 state;
2. asserts the official Cloudflare connectivity facts through:

   ```text
   GET /accounts/{account_id}/zerotrust/connectivity_settings
   ```

3. requires the adopted `adds` resource to exist in state;
4. runs the provider plan/read-back with `-detailed-exitcode`;
5. reports either:

   ```text
   NO CHANGES
   CHANGES REQUIRE REVIEW
   FAILED
   ```

Unexpected changes are a stop condition. There is no apply in this workflow.

## Read-only account assertions

Provider 5.24.0 exposes `cloudflare_zero_trust_device_settings` as a real data source. CF-1 reads/asserts the existing account-wide facts for:

- unique WARP/device IP assignment;
- Gateway TCP proxy;
- Gateway UDP proxy.

Cloudflare's official connectivity-settings API is additionally used to assert:

- WARP-to-WARP/off-ramp connectivity (`offramp_warp_enabled`);
- ICMP proxy (`icmp_proxy_enabled`).

If either fact is disabled or unreadable, provider planning fails closed.

The generated Cloudflare Terraform documentation describes `cloudflare_zero_trust_connectivity_settings`, but provider 5.24.0 does not register that data source. CF-1 therefore uses the official read-only API rather than introducing a custom provider, `local-exec` PATCH, or a second mutable control path.

## Credential boundaries

```text
PR head
  -> terraform fmt/lock/init -backend=false/validate only
  -> NO Cloudflare token
  -> NO R2 credentials

accepted protected main / operation=adopt
  -> GitHub-hosted runner installs Terraform 1.16.2
  -> protected cloudflare-plan inputs
  -> official read-only profile discovery
  -> remote R2 state import only
  -> NO plan / NO apply

accepted protected main / operation=plan
  -> protected cloudflare-plan inputs
  -> official connectivity read-back
  -> provider plan/read-back
  -> remote R2 state
  -> NO apply

physical Windows runner
  -> NO Cloudflare provider token
  -> NO R2 state credentials
  -> NO local-vault dependency for CF-1
```

The current Cloudflare provider documents `Zero Trust Write` for the custom-profile resource. If the currently configured `Zero Trust Read` token cannot perform import/refresh/read, fail closed and record the exact permission error. Any permission change is a separate explicit disposition and does not authorize apply.

## Forbidden shortcuts

- no provider credentials on pull-request heads;
- no local vault duplication solely to make CF-1 import work;
- no local Terraform installation requirement for the CF-1 operator path;
- no local mutable Cloudflare mirror database;
- no dashboard/MCP write path left as a permanent peer of Terraform;
- no custom provider or `local-exec` API mutation to compensate for provider schema gaps;
- no duplicate `adds` profile;
- no reuse of application R2 buckets for Terraform state;
- no duplicate vault/GitHub secrets under Terraform/S3 process-alias names;
- no AWS account/service introduced for the R2 backend;
- no provider/R2 credentials on the physical lab runner;
- no Android, Mesh TCP, E3 or E4 acceptance claim from this IaC stage.
