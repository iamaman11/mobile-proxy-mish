# Cloudflare IaC boundary

This directory is the repository-owned desired-configuration path for the bounded Cloudflare Zero Trust/Mesh configuration used by `mobile-proxy-mish`.

Cloudflare remains the live provider authority. Terraform state is deployment machinery only.

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

Do not create a duplicate profile. The profile match expression is supplied as a protected runtime secret and is not committed to this public repository.

The protected `match` selector contains operator identity data. Exact `name + match` verification therefore belongs to the hosted read-only Cloudflare API check on every accepted-main run. Terraform keeps the value in configuration for create/import shape but ignores update planning for `match` itself, because Terraform 1.16 sensitivity metadata can otherwise produce a perpetual metadata-only update even when the provider reports the exact same value. The verifier also confirms that the Terraform state resource ID points at the exact profile selected by the protected `name + match` predicate.

## Provider and Terraform versions

```text
Terraform             = 1.16.2
cloudflare/cloudflare  = 5.24.0
```

These are exact pins for CF-1. Upgrades require an ordinary reviewed PR. `infra/cloudflare/.terraform.lock.hcl` is committed dependency-integrity metadata. State, backend runtime files and tfvars remain excluded from Git.

## Remote state and protected execution boundary

The external bootstrap is materialized:

```text
R2 bucket             = mobile-proxy-mish-terraform-state
R2 credential scope   = that bucket only, Object Read & Write
hosted environment    = cloudflare-plan
```

Existing application buckets must not be reused for Terraform state. No provider or R2 credential belongs on the physical Windows runner.

The protected `cloudflare-plan` GitHub Environment is the execution-time credential source. A duplicate local protected vault and a local Terraform installation are not required for CF-1.

## Canonical protected inputs

The verifier consumes only:

```text
vars.R2_STATE_BUCKET
secrets.CLOUDFLARE_WINDOWS_PROFILE_MATCH
secrets.CLOUDFLARE_API_TOKEN
secrets.R2_ACCESS_KEY_ID
secrets.R2_SECRET_ACCESS_KEY
```

`CLOUDFLARE_ACCOUNT_ID` is no longer a workflow input. The accepted-main runner resolves the single account authorized by `CLOUDFLARE_API_TOKEN` through the official account-list API, requires exactly one account, masks the returned ID before reuse, and exports it only as the process-local Terraform variable.

The canonical stored project names are therefore:

```text
CLOUDFLARE_WINDOWS_PROFILE_MATCH
CLOUDFLARE_API_TOKEN
R2_STATE_BUCKET
R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY
```

No canonical project secret is named `TF_VAR_cloudflare_account_id`, `TF_VAR_windows_profile_match`, `AWS_ACCESS_KEY_ID`, or `AWS_SECRET_ACCESS_KEY`.

The hosted workflow maps protected values to process-only compatibility names immediately around Terraform execution:

```text
TF_VAR_cloudflare_account_id  <- masked account resolved from CLOUDFLARE_API_TOKEN scope
TF_VAR_windows_profile_match  <- CLOUDFLARE_WINDOWS_PROFILE_MATCH
AWS_ACCESS_KEY_ID             <- R2_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY         <- R2_SECRET_ACCESS_KEY
```

The `AWS_*` names are only the standard S3-backend compatibility interface. Their values are Cloudflare R2 credentials used against the masked account-specific Cloudflare R2 S3 endpoint. This project does not use an AWS account, AWS S3 bucket, or AWS runtime service for this state path.

## Single hosted verification procedure

`.github/workflows/cloudflare-terraform-plan.yml` is the single protected hosted operator path for CF-1 state adoption and provider verification.

It has two triggers for the same job and the same serialized state owner:

```text
manual workflow_dispatch with NO user inputs
automatic push to main only when this workflow or infra/cloudflare/** changes
```

Both triggers are:

```text
accepted-main only
GitHub-hosted only
protected by environment cloudflare-plan
serialized by cloudflare-terraform-provider-state
pinned to Terraform 1.16.2
NO apply path
```

The manual operator path remains one-click: the operator does not choose a branch, operation, account ID, token, bucket, profile match, or Terraform version. The automatic trigger exists so an accepted Cloudflare IaC change proves its own provider read-back immediately after merge instead of requiring another manual click. There is still only one verifier job, one credential source, one R2 state owner and one execution contract.

Every run additionally fails closed unless the checked-out ref is the exact current `main`.

A run performs the safe CF-1 sequence:

```text
accepted-main guard
 -> install/verify Terraform 1.16.2
 -> validate protected environment inputs
 -> resolve exactly one Cloudflare account from protected token scope and mask its ID
 -> initialize dedicated R2 backend
 -> read-only exact adds discovery by name + protected match on every run
 -> if adds absent from state: import that exact existing profile
 -> if adds already present: verify state identity points at that exact live profile
 -> assert required Mesh TCP/UDP connectivity settings
 -> observe ICMP diagnostic state without making it a TCP/UDP acceptance gate
 -> provider plan/read-back
 -> STOP
```

There is no Terraform apply in this workflow.

### Adoption behavior

The workflow always uses the official read-only Cloudflare endpoint:

```text
GET /accounts/{account_id}/devices/policies
```

It requires exactly one non-default profile whose:

```text
name  == adds
match == protected CLOUDFLARE_WINDOWS_PROFILE_MATCH
```

The discovered `policy_id` is masked ephemeral runtime data.

If Terraform state does not yet contain the resource, the workflow imports exactly that profile and verifies the adopted state identity matches the discovered live profile.

If Terraform state already contains the resource, the workflow does **not** skip selector verification: it re-runs the exact live `name + match` check and fails closed unless the state resource ID points to that same profile.

This makes the read-only API check the natural owner of the protected identity selector and prevents Terraform sensitivity metadata from creating a false provider update path.

If discovery is ambiguous, the API response is incomplete/paginated beyond the bounded request, protected inputs are absent, R2 initialization fails, state identity differs from the selected live profile, or provider import authority is insufficient, the run fails closed. Do not widen Cloudflare permissions implicitly.

### Provider verification behavior

After adoption is confirmed, the same run reads:

```text
GET /accounts/{account_id}/zerotrust/connectivity_settings
```

CF-1 requires:

```text
offramp_warp_enabled == true
```

The provider-backed `cloudflare_zero_trust_device_settings` check separately requires:

```text
use_zt_virtual_ip == true
gateway_proxy_enabled == true
gateway_udp_proxy_enabled == true
```

These are the fail-closed account-wide prerequisites for the accepted TCP/UDP Mesh dataplane.

`icmp_proxy_enabled` is diagnostic-only for CF-1. Current Cloudflare Mesh documentation distinguishes TCP/UDP proxying from ICMP and describes ICMP as useful/recommended for diagnostic tools such as `ping` and `traceroute`. Therefore the workflow reports ICMP as `ENABLED`, `DISABLED`, or `NOT EXPOSED`, but none of those three observation states alone changes CF-1 TCP/UDP acceptance.

This is not a weakening of the product dataplane contract: the application architecture requires TCP/UDP Mesh transport, while ICMP is not used by the proxy dataplane.

The workflow then runs Terraform provider plan/read-back with `-detailed-exitcode`.

Raw Terraform plan output is never printed to the public Actions log because provider refresh output can contain operator-specific resource IDs and a future drift plan could contain protected values. Raw plan/log/JSON material stays only in ephemeral runner storage with restrictive permissions and is deleted at job exit.

Public result semantics are intentionally strict:

```text
exit 0 -> NO CHANGES -> workflow success
exit 2 -> CHANGES REQUIRE REVIEW -> safe attribute-name-only summary -> workflow failure
other  -> FAILED -> workflow failure
```

A green verifier therefore means a genuinely clean provider plan, not merely that Terraform produced a reviewable diff. No plan change authorizes apply.

## Read-only account assertions

Provider 5.24.0 exposes `cloudflare_zero_trust_device_settings` as a real data source. CF-1 reads/asserts the existing account-wide facts for:

- unique WARP/device IP assignment;
- Gateway TCP proxy;
- Gateway UDP proxy.

Cloudflare's official connectivity-settings API additionally asserts WARP-to-WARP/off-ramp connectivity. The ICMP proxy field is recorded only as diagnostic evidence for this stage.

The generated Cloudflare Terraform documentation describes `cloudflare_zero_trust_connectivity_settings`, but provider 5.24.0 does not register that data source. CF-1 therefore uses the official read-only API rather than introducing a custom provider, `local-exec` PATCH, or a second mutable control path.

## Credential boundaries

```text
PR head
  -> terraform fmt/lock/init -backend=false/validate only
  -> NO Cloudflare token
  -> NO R2 credentials

accepted protected main / hosted verifier
  -> manual one-click OR path-filtered automatic push trigger
  -> same GitHub-hosted runner job
  -> protected cloudflare-plan inputs
  -> masked account resolution from token scope
  -> exact protected selector verification through read-only Cloudflare API
  -> remote R2 state import only when absent
  -> state/live identity equality check
  -> official connectivity read-back
  -> sanitized provider plan/read-back
  -> NO apply

physical Windows runner
  -> NO Cloudflare provider token
  -> NO R2 state credentials
  -> NO local-vault dependency for CF-1
```

Provider v5.24.0 import for `cloudflare_zero_trust_device_custom_profile` accepts `<account_id>/<policy_id>` and reads the existing resource during ImportState. If the configured `Zero Trust Read` token cannot perform required account resolution, discovery, import, or read-back, fail closed and record the exact permission error. Any permission change is a separate explicit disposition and does not authorize apply.

## Forbidden shortcuts

- no provider credentials on pull-request heads;
- no local vault duplication solely to make CF-1 work;
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
