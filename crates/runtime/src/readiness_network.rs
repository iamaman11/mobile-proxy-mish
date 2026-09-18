//! Rust/Tokio execution of the authenticated readiness network probe.
//!
//! Readiness semantics/freshness stay in mish-readiness/mish-application. This module owns only
//! the concrete bounded network effect: loopback HTTP CONNECT to the native proxy followed by a
//! certificate- and hostname-verified TLS handshake on the existing shared PRODUCT Tokio runtime.

use crate::tls_client::{ProductTlsClient, ProductTlsError};
use crate::{RuntimeExecutionError, RuntimeExecutor};
use mish_application::DEFAULT_EGRESS_PROBE_BUDGET;
use mish_configuration::ReadinessProbeTarget;
use mish_proxy::{HTTP_CONNECT_PORT, ProxyCredentialMaterial};
use mish_readiness::ProbeOutcome;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::{Instant, timeout_at};

const MAX_CONNECT_HEADER_BYTES: usize = 8_192;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadinessNetworkError {
    InvalidTarget,
    InvalidCredentials,
    ExecutorUnavailable,
    TlsConfiguration,
}

pub fn execute_readiness_probe(
    executor: &RuntimeExecutor,
    username: String,
    password: String,
) -> Result<ProbeOutcome, ReadinessNetworkError> {
    let target =
        ReadinessProbeTarget::deployment().map_err(|_| ReadinessNetworkError::InvalidTarget)?;
    let credentials = ProxyCredentialMaterial::new(username, password)
        .map_err(|_| ReadinessNetworkError::InvalidCredentials)?;
    let tls = ProductTlsClient::new().map_err(|_| ReadinessNetworkError::TlsConfiguration)?;

    executor
        .block_on(execute_probe(&target, &credentials, &tls))
        .map_err(map_execution_error)
}

async fn execute_probe(
    target: &ReadinessProbeTarget,
    credentials: &ProxyCredentialMaterial,
    tls: &ProductTlsClient,
) -> ProbeOutcome {
    let deadline = Instant::now() + DEFAULT_EGRESS_PROBE_BUDGET;
    let socket = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), HTTP_CONNECT_PORT);
    let mut stream = match timeout_at(deadline, TcpStream::connect(socket)).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(_)) => return ProbeOutcome::TransportFailed,
        Err(_) => return ProbeOutcome::Timeout,
    };

    let authority = format!("{}:{}", target.hostname(), target.port());
    let authorization = credentials.basic_authorization_value();
    let request = format!(
        "CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\nProxy-Authorization: {authorization}\r\nProxy-Connection: keep-alive\r\n\r\n"
    );

    match timeout_at(deadline, stream.write_all(request.as_bytes())).await {
        Ok(Ok(())) => {}
        Ok(Err(_)) => return ProbeOutcome::TransportFailed,
        Err(_) => return ProbeOutcome::Timeout,
    }
    match timeout_at(deadline, stream.flush()).await {
        Ok(Ok(())) => {}
        Ok(Err(_)) => return ProbeOutcome::TransportFailed,
        Err(_) => return ProbeOutcome::Timeout,
    }

    let header = match read_connect_header(&mut stream, deadline).await {
        Ok(header) => header,
        Err(outcome) => return outcome,
    };
    let connect = classify_connect_header(&header);
    if connect != ProbeOutcome::Succeeded {
        return connect;
    }

    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return ProbeOutcome::Timeout;
    }
    match tls.connect(stream, target.hostname(), remaining).await {
        Ok(_stream) => ProbeOutcome::Succeeded,
        Err(ProductTlsError::DeadlineExceeded) => ProbeOutcome::Timeout,
        Err(ProductTlsError::InvalidServerName)
        | Err(ProductTlsError::Configuration)
        | Err(ProductTlsError::HandshakeFailed) => ProbeOutcome::TlsFailed,
    }
}

async fn read_connect_header(
    stream: &mut TcpStream,
    deadline: Instant,
) -> Result<Vec<u8>, ProbeOutcome> {
    let mut response = Vec::with_capacity(512);
    let mut chunk = [0_u8; 512];

    loop {
        if response.len() >= MAX_CONNECT_HEADER_BYTES {
            return Err(ProbeOutcome::TransportFailed);
        }
        let remaining = MAX_CONNECT_HEADER_BYTES - response.len();
        let read = match timeout_at(deadline, stream.read(&mut chunk[..remaining.min(chunk.len())]))
            .await
        {
            Ok(Ok(read)) => read,
            Ok(Err(_)) => return Err(ProbeOutcome::TransportFailed),
            Err(_) => return Err(ProbeOutcome::Timeout),
        };
        if read == 0 {
            return Err(ProbeOutcome::TransportFailed);
        }
        response.extend_from_slice(&chunk[..read]);
        if let Some(end) = response.windows(4).position(|window| window == b"\r\n\r\n") {
            response.truncate(end + 4);
            return Ok(response);
        }
    }
}

fn classify_connect_header(header: &[u8]) -> ProbeOutcome {
    let Some(line_end) = header.windows(2).position(|window| window == b"\r\n") else {
        return ProbeOutcome::TransportFailed;
    };
    let Ok(status_line) = std::str::from_utf8(&header[..line_end]) else {
        return ProbeOutcome::TransportFailed;
    };
    let mut parts = status_line.split_whitespace();
    let Some(protocol) = parts.next() else {
        return ProbeOutcome::TransportFailed;
    };
    let Some(status) = parts.next().and_then(|raw| raw.parse::<u16>().ok()) else {
        return ProbeOutcome::TransportFailed;
    };
    if !matches!(protocol, "HTTP/1.0" | "HTTP/1.1") {
        return ProbeOutcome::TransportFailed;
    }
    match status {
        407 => ProbeOutcome::AuthenticationFailed,
        200..=299 => ProbeOutcome::Succeeded,
        _ => ProbeOutcome::TransportFailed,
    }
}

fn map_execution_error(_error: RuntimeExecutionError) -> ReadinessNetworkError {
    ReadinessNetworkError::ExecutorUnavailable
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connect_status_parser_is_exact() {
        assert_eq!(
            classify_connect_header(b"HTTP/1.1 200 Connection established\r\n\r\n"),
            ProbeOutcome::Succeeded
        );
        assert_eq!(
            classify_connect_header(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n"),
            ProbeOutcome::AuthenticationFailed
        );
        assert_eq!(
            classify_connect_header(b"HTTP/1.1 503 Unavailable\r\n\r\n"),
            ProbeOutcome::TransportFailed
        );
        assert_eq!(
            classify_connect_header(b"not-http\r\n\r\n"),
            ProbeOutcome::TransportFailed
        );
    }

    #[test]
    fn invalid_credentials_fail_before_network_execution() {
        let executor = RuntimeExecutor::new().expect("runtime");
        assert_eq!(
            execute_readiness_probe(&executor, String::new(), "password".to_owned()),
            Err(ReadinessNetworkError::InvalidCredentials)
        );
        executor.shutdown().expect("shutdown");
    }
}
