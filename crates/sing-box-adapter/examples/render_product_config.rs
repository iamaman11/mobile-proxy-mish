use std::net::{IpAddr, Ipv4Addr};

use mish_proxy::{ProxyCredentialMaterial, ProxyServingPlan};
use mish_sing_box_adapter::{PrivateSocks5Endpoint, render_product_config};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let plan = ProxyServingPlan::canonical(
        IpAddr::V4(Ipv4Addr::LOCALHOST),
        ProxyCredentialMaterial::new("ci-public", "ci-public-password")?,
    )?;
    let egress = PrivateSocks5Endpoint::new(
        IpAddr::V4(Ipv4Addr::LOCALHOST),
        19080,
        "ci-egress",
        "ci-egress-password",
    )?;

    print!("{}", render_product_config(&plan, &egress)?);
    Ok(())
}
