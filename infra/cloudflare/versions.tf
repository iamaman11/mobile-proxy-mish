terraform {
  required_version = "= 1.16.1"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "= 5.24.0"
    }
  }

  # Production state is stored in a dedicated R2 bucket through the
  # S3-compatible backend. Backend coordinates and credentials are supplied
  # at init time and are never committed to Git.
  backend "s3" {}
}
