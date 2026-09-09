provider "cloudflare" {
  # Authentication is supplied only through CLOUDFLARE_API_TOKEN in the
  # protected hosted plan/apply environment. No credential is accepted from
  # repository variables or the physical Windows runner.
}
