//! Android arm64 link proof for the concrete B4b-2 cellular outbound connector.
//!
//! This binary is never an E3 runtime test. Its only purpose is to force the concrete
//! `CellularOutboundConnector` implementation and its exact-network DNS/connect
//! primitives into an Android-linked artifact so CI can verify the complete path.

#[cfg(target_os = "android")]
fn main() {
    use mish_android_network::{AndroidConnectError, AndroidNetworkError};
    use mish_cellular::CellularNetworkAuthority;
    use mish_cellular_egress_bridge::{
        CellularOutboundConnector, ConnectTarget, OutboundConnectError,
    };
    use mish_runtime::AndroidCellularOutboundConnector;
    use std::net::{SocketAddr, TcpStream};
    use std::time::Instant;

    let connector_method: fn(
        &AndroidCellularOutboundConnector,
        &ConnectTarget,
    ) -> Result<TcpStream, OutboundConnectError> =
        <AndroidCellularOutboundConnector as CellularOutboundConnector>::connect;

    let resolve_method: fn(
        CellularNetworkAuthority,
        &str,
    ) -> Result<Vec<String>, AndroidNetworkError> = mish_android_network::resolve_host;

    let connect_method: fn(
        CellularNetworkAuthority,
        SocketAddr,
        Instant,
    ) -> Result<TcpStream, AndroidConnectError> = mish_android_network::connect_tcp_until;

    std::hint::black_box((connector_method, resolve_method, connect_method));
}

#[cfg(not(target_os = "android"))]
fn main() {}
