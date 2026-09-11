//! Android link proof for the concrete Cellular Egress connector.
//!
//! The binary forces the production connector and transitional network-scoped DNS adapter
//! into one Android artifact. CI uses it to prove `android_getaddrinfofornetwork` remains
//! available while the physically superseded `android_setsocknetwork` path is absent.

#[cfg(target_os = "android")]
fn main() {
    use mish_android_network::AndroidNetworkError;
    use mish_cellular::CellularNetworkAuthority;
    use mish_cellular_egress_bridge::{
        CellularOutboundConnector, ConnectTarget, OutboundConnectError,
    };
    use mish_runtime::AndroidCellularOutboundConnector;
    use std::net::TcpStream;

    let connector_method: fn(
        &AndroidCellularOutboundConnector,
        &ConnectTarget,
    ) -> Result<TcpStream, OutboundConnectError> =
        <AndroidCellularOutboundConnector as CellularOutboundConnector>::connect;

    let resolve_method: fn(
        CellularNetworkAuthority,
        &str,
    ) -> Result<Vec<String>, AndroidNetworkError> = mish_android_network::resolve_host;

    std::hint::black_box((connector_method, resolve_method));
}

#[cfg(not(target_os = "android"))]
fn main() {}
