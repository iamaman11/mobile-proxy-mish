//! Shared PRODUCT TLS mechanism for ordinary Tokio sockets.
//!
//! Endpoint identity, HTTP/CONNECT semantics and owner currentness live in their respective
//! capability modules. This module owns only certificate roots, hostname verification and the
//! bounded asynchronous TLS handshake.

use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::time::timeout;
use tokio_rustls::rustls::pki_types::ServerName;
use tokio_rustls::rustls::{ClientConfig, RootCertStore};
use tokio_rustls::{TlsConnector, client::TlsStream};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ProductTlsError {
    Configuration,
    InvalidServerName,
    DeadlineExceeded,
    HandshakeFailed,
}

#[derive(Clone)]
pub(crate) struct ProductTlsClient {
    connector: TlsConnector,
}

impl ProductTlsClient {
    pub(crate) fn new() -> Result<Self, ProductTlsError> {
        let mut roots = RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        let config = ClientConfig::builder_with_provider(Arc::new(
            tokio_rustls::rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .map_err(|_| ProductTlsError::Configuration)?
        .with_root_certificates(roots)
        .with_no_client_auth();
        Ok(Self {
            connector: TlsConnector::from(Arc::new(config)),
        })
    }

    pub(crate) async fn connect(
        &self,
        stream: TcpStream,
        hostname: &str,
        remaining: Duration,
    ) -> Result<TlsStream<TcpStream>, ProductTlsError> {
        if remaining.is_zero() {
            return Err(ProductTlsError::DeadlineExceeded);
        }
        let server_name = ServerName::try_from(hostname.to_owned())
            .map_err(|_| ProductTlsError::InvalidServerName)?;
        timeout(remaining, self.connector.connect(server_name, stream))
            .await
            .map_err(|_| ProductTlsError::DeadlineExceeded)?
            .map_err(|_| ProductTlsError::HandshakeFailed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn product_tls_config_builds_with_explicit_ring_provider_and_mozilla_roots() {
        assert!(ProductTlsClient::new().is_ok());
    }

    #[test]
    fn invalid_dns_name_is_rejected_without_network_effect() {
        let client = ProductTlsClient::new().expect("TLS client");
        let name = ServerName::try_from("bad host".to_owned());
        assert!(name.is_err());
        drop(client);
    }
}
