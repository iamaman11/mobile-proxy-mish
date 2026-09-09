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

The following existing account-wide settings are read and asserted, not mutated by this stage:

- unique WARP/device IP assignment;
- Gateway TCP proxy;
- Gateway UDP proxy;
- WARP-to-WARP/off-ramp connectivity;
- ICMP proxy.

The provider exposes these through `cloudflare_zero_trust_device_settings` and `cloudflare_zero_trust_connectivity_settings`. A future stage may take write ownership only after an accepted no-drift provider plan proves the exact mapping and there is a concrete need to manage those settings.

## Provider and Terraform versions

```text
Terraform             = 1.16.1
cloudflare/cloudflare  = 5.24.0
```

These are exact pins for CF-1. Upgrades require an ordinary reviewed PR.

## Remote state bootstrap

A dedicated R2 bucket does not yet exist. Existing application buckets must **not** be reused for Terraform state.

One bounded bootstrap action is required:

1. Create a dedicated R2 bucket for this repository's Terraform state.
2. Create bucket-scoped R2 credentials with Object Read & Write only.
3. Store the R2 credentials only in the protected GitHub hosted environment used for provider plan/state operations.
4. Copy `backend.r2.hcl.example` outside Git, replace placeholders, and initialize the S3-compatible R2 backend.

Never place R2 access keys, Cloudflare API tokens, backend credentials, or local backend files in Git.

## Existing profile adoption

The existing `adds` profile is imported once; import changes Terraform state only and must not mutate the Cloudflare profile.

From an accepted `main` checkout with the remote backend initialized and the required provider credentials available:

```bash
terraform -chdir=infra/cloudflare import \
  cloudflare_zero_trust_device_custom_profile.adds \
  "$CLOUDFLARE_ACCOUNT_ID/$CLOUDFLARE_ADDS_POLICY_ID"
```

Then run a normal plan immediately.

```bash
terraform -chdir=infra/cloudflare plan
```

If the plan proposes any unexpected provider change, **do not apply**. Fix the desired configuration in a new PR and repeat from accepted `main`.

## Runtime inputs

Required inputs are supplied outside Git:

```text
TF_VAR_cloudflare_account_id
TF_VAR_windows_profile_match
CLOUDFLARE_API_TOKEN
```

The one-time import additionally requires:

```text
CLOUDFLARE_ADDS_POLICY_ID
```

R2 backend initialization uses:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

plus a non-secret backend configuration derived from `backend.r2.hcl.example`.

## Credential boundaries

```text
PR head
  -> terraform fmt/init -backend=false/validate only
  -> NO Cloudflare token
  -> NO R2 credentials

accepted protected main
  -> credentialed hosted provider plan/read-back
  -> remote R2 state

protected/manual accepted main
  -> explicit apply only after reviewed plan

physical Windows runner
  -> NO Cloudflare provider token
  -> NO R2 state credentials
```

The current Cloudflare provider documents `Zero Trust Write` for the custom-profile resource. If a genuinely read-only provider token cannot perform Terraform refresh/plan for this resource, the hosted plan credential may require that permission; this does not authorize apply. Apply remains a separate protected operation.

## Forbidden shortcuts

- no provider credentials on pull-request heads;
- no local mutable Cloudflare mirror database;
- no dashboard/MCP write path left as a permanent peer of Terraform;
- no duplicate `adds` profile;
- no reuse of application R2 buckets for Terraform state;
- no provider/R2 credentials on the physical lab runner;
- no Android, Mesh TCP, E3 or E4 acceptance claim from this IaC stage.
