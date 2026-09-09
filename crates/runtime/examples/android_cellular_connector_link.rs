//! Android arm64 link proof for the concrete B4b-2 cellular outbound connector.
//!
//! This binary is never an E3 runtime test. Its only purpose is to force the concrete
//! `CellularOutboundConnector` implementation into an Android-linked artifact so CI can
//! verify that the exact-network NDK DNS/bind/connect path is present.

#[cfg(target_os = "android")]
fn main() {
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

    std::hint::black_box(connector_method);
}

#[cfg(not(target_os = "android"))]
fn main() {}
