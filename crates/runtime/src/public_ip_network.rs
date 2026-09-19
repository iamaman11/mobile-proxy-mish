//! Tokio execution of the existing generation-bound U4 public-IP observation.
//!
//! The U4 owner contract remains in public_ip.rs/cellular_runtime.rs. This module replaces the
//! transitional Kotlin Socket/SSLSocket/HTTP effect with ordinary PRODUCT-UID Tokio TCP + rustls.

use crate::tls_client::{ProductTlsClient, ProductTlsError};
use crate::{
    PublicEgressIpObservation, PublicIpProbeEffectFailure, PublicIpProbeFailure,
    RuntimePublicIpProbe,
};
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::timeout;

const HTTP_RESPONSE_MAX_BYTES: usize = 2_048;

pub(crate) async fn execute_public_ip_probe(
    probe: RuntimePublicIpProbe,
    tls: &ProductTlsClient,
) -> Result<PublicEgressIpObservation, PublicIpProbeFailure> {
    let addresses = probe.numeric_addresses();
    if addresses.is_empty() {
        return Err(probe.effect_failed(PublicIpProbeEffectFailure::ResponseMalformed));
    }

    let mut last_retryable = PublicIpProbeEffectFailure::SocketConnect;
    for raw in addresses {
        let address = match raw.parse::<IpAddr>() {
            Ok(address) => address,
            Err(_) => {
                return Err(probe.effect_failed(PublicIpProbeEffectFailure::ResponseMalformed));
            }
        };

        match execute_candidate(&probe, tls, address).await {
            Ok(body) => return probe.complete(&body),
            Err(CandidateFailure::Retryable(failure)) => {
                last_retryable = failure;
            }
            Err(CandidateFailure::Terminal(failure)) => {
                return Err(probe.effect_failed(failure));
            }
        }
    }

    Err(probe.effect_failed(last_retryable))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CandidateFailure {
    Retryable(PublicIpProbeEffectFailure),
    Terminal(PublicIpProbeEffectFailure),
}

async fn execute_candidate(
    probe: &RuntimePublicIpProbe,
    tls: &ProductTlsClient,
    address: IpAddr,
) -> Result<String, CandidateFailure> {
    let socket = SocketAddr::new(address, probe.port());
    let stream = timeout(
        remaining(probe).map_err(CandidateFailure::Terminal)?,
        TcpStream::connect(socket),
    )
    .await
    .map_err(|_| CandidateFailure::Retryable(PublicIpProbeEffectFailure::SocketTimeout))?
    .map_err(|_| CandidateFailure::Retryable(PublicIpProbeEffectFailure::SocketConnect))?;

    let mut stream = tls
        .connect(
            stream,
            probe.host(),
            remaining(probe).map_err(CandidateFailure::Terminal)?,
        )
        .await
        .map_err(map_tls_failure)?;

    let request = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\nUser-Agent: mobile-proxy-mish-u4\r\nAccept: text/plain\r\n\r\n",
        probe.path(),
        probe.host(),
    );

    timeout(
        remaining(probe).map_err(CandidateFailure::Terminal)?,
        stream.write_all(request.as_bytes()),
    )
    .await
    .map_err(|_| CandidateFailure::Retryable(PublicIpProbeEffectFailure::SocketTimeout))?
    .map_err(|_| CandidateFailure::Retryable(PublicIpProbeEffectFailure::Io))?;

    timeout(
        remaining(probe).map_err(CandidateFailure::Terminal)?,
        stream.flush(),
    )
    .await
    .map_err(|_| CandidateFailure::Retryable(PublicIpProbeEffectFailure::SocketTimeout))?
    .map_err(|_| CandidateFailure::Retryable(PublicIpProbeEffectFailure::Io))?;

    let mut response = Vec::with_capacity(512);
    let read = timeout(
        remaining(probe).map_err(CandidateFailure::Terminal)?,
        (&mut stream)
            .take((HTTP_RESPONSE_MAX_BYTES + 1) as u64)
            .read_to_end(&mut response),
    )
    .await
    .map_err(|_| CandidateFailure::Retryable(PublicIpProbeEffectFailure::SocketTimeout))?
    .map_err(|_| CandidateFailure::Retryable(PublicIpProbeEffectFailure::Io))?;

    if read > HTTP_RESPONSE_MAX_BYTES {
        return Err(CandidateFailure::Terminal(
            PublicIpProbeEffectFailure::ResponseTooLarge,
        ));
    }

    parse_http_200_body(&response, probe.response_body_max_bytes())
        .map_err(CandidateFailure::Terminal)
}

fn remaining(probe: &RuntimePublicIpProbe) -> Result<Duration, PublicIpProbeEffectFailure> {
    probe
        .remaining_timeout_ms()
        .map(Duration::from_millis)
        .map_err(|failure| match failure {
            PublicIpProbeFailure::DeadlineExceeded => PublicIpProbeEffectFailure::SocketTimeout,
            PublicIpProbeFailure::RootPolicyUnavailable
            | PublicIpProbeFailure::StaleGeneration
            | PublicIpProbeFailure::NoCurrentCellular
            | PublicIpProbeFailure::DnsUnavailable
            | PublicIpProbeFailure::InvalidResponse
            | PublicIpProbeFailure::SocketConnect
            | PublicIpProbeFailure::SocketTimeout
            | PublicIpProbeFailure::TlsHandshake
            | PublicIpProbeFailure::TlsHostname
            | PublicIpProbeFailure::HttpStatus
            | PublicIpProbeFailure::ResponseTooLarge
            | PublicIpProbeFailure::ResponseMalformed
            | PublicIpProbeFailure::Io => PublicIpProbeEffectFailure::Io,
        })
}

fn map_tls_failure(error: ProductTlsError) -> CandidateFailure {
    match error {
        ProductTlsError::InvalidServerName => {
            CandidateFailure::Terminal(PublicIpProbeEffectFailure::TlsHostname)
        }
        ProductTlsError::Configuration | ProductTlsError::HandshakeFailed => {
            CandidateFailure::Retryable(PublicIpProbeEffectFailure::TlsHandshake)
        }
        ProductTlsError::DeadlineExceeded => {
            CandidateFailure::Retryable(PublicIpProbeEffectFailure::SocketTimeout)
        }
    }
}

fn parse_http_200_body(
    response: &[u8],
    max_body_bytes: usize,
) -> Result<String, PublicIpProbeEffectFailure> {
    let separator = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or(PublicIpProbeEffectFailure::ResponseMalformed)?;
    let header = std::str::from_utf8(&response[..separator])
        .map_err(|_| PublicIpProbeEffectFailure::ResponseMalformed)?;
    let status = header
        .lines()
        .next()
        .ok_or(PublicIpProbeEffectFailure::ResponseMalformed)?;
    let mut status_parts = status.split_whitespace();
    let protocol = status_parts
        .next()
        .ok_or(PublicIpProbeEffectFailure::ResponseMalformed)?;
    let status_code = status_parts
        .next()
        .and_then(|raw| raw.parse::<u16>().ok())
        .ok_or(PublicIpProbeEffectFailure::ResponseMalformed)?;
    if !matches!(protocol, "HTTP/1.0" | "HTTP/1.1") || status_code != 200 {
        return Err(PublicIpProbeEffectFailure::HttpStatus);
    }

    let body = &response[separator + 4..];
    if body.len() > max_body_bytes {
        return Err(PublicIpProbeEffectFailure::ResponseTooLarge);
    }
    std::str::from_utf8(body)
        .map(str::to_owned)
        .map_err(|_| PublicIpProbeEffectFailure::ResponseMalformed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn http_parser_accepts_only_success_with_bounded_body() {
        assert_eq!(
            parse_http_200_body(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n1.2.3.4\n", 64),
            Ok("1.2.3.4\n".to_owned())
        );
        assert_eq!(
            parse_http_200_body(b"HTTP/1.1 503 Nope\r\n\r\nno", 64),
            Err(PublicIpProbeEffectFailure::HttpStatus)
        );
        assert_eq!(
            parse_http_200_body(b"HTTP/1.1 200 OK\r\n\r\n12345", 4),
            Err(PublicIpProbeEffectFailure::ResponseTooLarge)
        );
        assert_eq!(
            parse_http_200_body(b"not-http", 64),
            Err(PublicIpProbeEffectFailure::ResponseMalformed)
        );
    }
}
