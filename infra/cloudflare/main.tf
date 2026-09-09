resource "cloudflare_zero_trust_device_custom_profile" "adds" {
  account_id = var.cloudflare_account_id
  name       = "adds"
  match      = var.windows_profile_match
  precedence = 1000
  enabled    = true

  allow_mode_switch              = false
  auto_connect                   = 0
  disable_auto_fallback          = true
  register_interface_ip_with_dns = false
  tunnel_protocol                = "masque"

  service_mode_v2 = {
    mode = "warp_tunnel_only"
  }

  include = [{
    address     = var.mesh_device_cidr
    description = "Cloudflare Mesh destinations"
  }]

  lifecycle {
    # CF-1 intentionally adopts only the fields that define the accepted
    # Windows Mesh-routing contract. Other pre-existing profile preferences
    # remain provider/live-state facts until a concrete stage assigns them a
    # natural owner. Import + plan must therefore not rewrite them by accident.
    #
    # `match` is a protected operator-identity selector. Terraform 1.16 marks
    # the sensitive input metadata even when the provider reports the exact same
    # value, which creates a perpetual metadata-only update plan. The hosted
    # verifier therefore owns exact `name + match` read-back through Cloudflare's
    # official read-only device-policies API on every run and verifies that the
    # adopted state ID points at that exact live profile. Terraform must not try
    # to rewrite this sensitive selector merely to change local sensitivity
    # metadata.
    ignore_changes = [
      match,
      allow_updates,
      allowed_to_leave,
      captive_portal,
      description,
      dns_search_suffixes,
      exclude_office_ips,
      global_acceleration,
      lan_allow_minutes,
      lan_allow_subnet_size,
      sccm_vpn_boundary_support,
      support_url,
      switch_locked,
      virtual_networks,
    ]

    prevent_destroy = true
  }
}

# These account-wide facts already exist and are required for the accepted
# TCP/UDP Mesh dataplane. Provider 5.24.0 exposes a read-only device-settings
# data source for unique virtual IP assignment plus Gateway TCP/UDP proxying,
# so CF-1 can assert those facts without taking write ownership of the
# account-wide singleton.
data "cloudflare_zero_trust_device_settings" "mesh" {
  account_id = var.cloudflare_account_id
}

check "mesh_device_settings" {
  assert {
    condition = (
      data.cloudflare_zero_trust_device_settings.mesh.use_zt_virtual_ip &&
      data.cloudflare_zero_trust_device_settings.mesh.gateway_proxy_enabled &&
      data.cloudflare_zero_trust_device_settings.mesh.gateway_udp_proxy_enabled
    )
    error_message = "Cloudflare Mesh requires unique device IPs plus Gateway TCP and UDP proxying."
  }
}

# WARP-to-WARP/off-ramp connectivity remains a mandatory live account fact and
# is asserted through Cloudflare's official read-only connectivity-settings API.
# `icmp_proxy_enabled` is observed only as a diagnostic capability: current
# Cloudflare Mesh documentation treats ICMP as useful/recommended for ping and
# traceroute, while the accepted product dataplane requires TCP/UDP. Therefore
# ICMP true/false/omitted is reported but is not a CF-1 acceptance gate.
# Provider 5.24.0 still does not register the documented connectivity-settings
# Terraform data source in its actual plugin schema, so no custom provider or
# second write path is introduced.
