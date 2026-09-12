variable "cloudflare_account_id" {
  description = "Cloudflare account ID. Supplied by the protected hosted environment, not committed as a repository default."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "cloudflare_account_id must be a 32-character lowercase hexadecimal Cloudflare account ID."
  }
}

variable "windows_profile_match" {
  description = "Exact Cloudflare device-profile match expression for the adopted Windows lab profile. Kept out of public Git because it contains operator identity data."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.windows_profile_match)) > 0
    error_message = "windows_profile_match must not be empty."
  }
}
