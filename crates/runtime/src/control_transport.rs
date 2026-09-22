//! Small WebSocket transport adapter for the outbound MISH control session.
//!
//! PRODUCT/session semantics stay in `control_runtime`. This module owns only bounded
//! DNS/TCP/TLS/WebSocket mechanics on the already-owned PRODUCT Tokio runtime.

use crate::tls_client::ProductTlsClient;
use futures_util::{SinkExt, StreamExt};
use mish_control::CONTROL_WIRE_MAX_BYTES;
use std::time::Duration;
use tokio::net::{TcpStream, lookup_host};
use tokio::time::{Instant, timeout};
use tokio_rustls::client::TlsStream;
use tokio_tungstenite::tungstenite::Error as WebSocketError;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::http::header::USER_AGENT;
use tokio_tungstenite::tungstenite::protocol::{Message, WebSocketConfig};
use tokio_tungstenite::{WebSocketStream, client_async_with_config};

const CONTROL_WEBSOCKET_FRAMING_HEADROOM_BYTES: usize = 256;
const CONTROL_WEBSOCKET_MAX_BYTES: usize =
    CONTROL_WIRE_MAX_BYTES + CONTROL_WEBSOCKET_FRAMING_HEADROOM_BYTES;
const CONTROL_READ_BUFFER_BYTES: usize = 4 * 1024;
const CONTROL_MAX_WRITE_BUFFER_BYTES: usize = 4 * 1024;
const CONTROL_USER_AGENT: &str = "mobile-proxy-mish-control/1";

type ControlSocket = WebSocketStream<TlsStream<TcpStream>>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ControlTransportMessage {
    Text(String),
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ControlTransportError {
    Network,
    Tls,
    WebSocket,
    Protocol,
}

pub(crate) struct ControlTransport {
    socket: ControlSocket,
}

impl ControlTransport {
    pub(crate) async fn connect(
        host: &str,
        port: u16,
        path: &str,
        device_id: &str,
        operation_timeout: Duration,
    ) -> Result<Self, ControlTransportError> {
        let deadline = Instant::now() + operation_timeout;
        let tcp = connect_tcp(host, port, deadline).await?;
        let remaining = deadline.saturating_duration_since(Instant::now());
        let tls = ProductTlsClient::new().map_err(|_| ControlTransportError::Tls)?;
        let tls_stream = tls
            .connect(tcp, host, remaining)
            .await
            .map_err(|_| ControlTransportError::Tls)?;

        let request = build_request(host, port, path, device_id)?;
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(ControlTransportError::WebSocket);
        }
        let (socket, _) = timeout(
            remaining,
            client_async_with_config(request, tls_stream, Some(websocket_config())),
        )
        .await
        .map_err(|_| ControlTransportError::WebSocket)?
        .map_err(classify_websocket_error)?;

        Ok(Self { socket })
    }

    pub(crate) async fn write_text(&mut self, text: &str) -> Result<(), ControlTransportError> {
        if text.len() > CONTROL_WIRE_MAX_BYTES {
            return Err(ControlTransportError::Protocol);
        }
        self.socket
            .send(Message::text(text.to_owned()))
            .await
            .map_err(classify_websocket_error)
    }

    pub(crate) async fn read_message(
        &mut self,
    ) -> Result<ControlTransportMessage, ControlTransportError> {
        loop {
            let Some(message) = self.socket.next().await else {
                return Ok(ControlTransportMessage::Closed);
            };
            let message = message.map_err(classify_websocket_error)?;
            if let Some(message) = classify_message(message)? {
                return Ok(message);
            }
        }
    }
}

async fn connect_tcp(
    host: &str,
    port: u16,
    deadline: Instant,
) -> Result<TcpStream, ControlTransportError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(ControlTransportError::Network);
    }
    let addresses = timeout(remaining, lookup_host((host, port)))
        .await
        .map_err(|_| ControlTransportError::Network)?
        .map_err(|_| ControlTransportError::Network)?;

    for address in addresses {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match timeout(remaining, TcpStream::connect(address)).await {
            Ok(Ok(stream)) => return Ok(stream),
            Ok(Err(_)) | Err(_) => continue,
        }
    }
    Err(ControlTransportError::Network)
}

fn build_request(
    host: &str,
    port: u16,
    path: &str,
    device_id: &str,
) -> Result<tokio_tungstenite::tungstenite::http::Request<()>, ControlTransportError> {
    let authority = if port == 443 {
        host.to_owned()
    } else {
        format!("{host}:{port}")
    };
    let uri = format!("wss://{authority}{path}?device_id={device_id}");
    let mut request = uri
        .into_client_request()
        .map_err(|_| ControlTransportError::Protocol)?;
    request
        .headers_mut()
        .insert(USER_AGENT, HeaderValue::from_static(CONTROL_USER_AGENT));
    Ok(request)
}

fn websocket_config() -> WebSocketConfig {
    WebSocketConfig::default()
        .read_buffer_size(CONTROL_READ_BUFFER_BYTES)
        .write_buffer_size(0)
        .max_write_buffer_size(CONTROL_MAX_WRITE_BUFFER_BYTES)
        .max_message_size(Some(CONTROL_WEBSOCKET_MAX_BYTES))
        .max_frame_size(Some(CONTROL_WEBSOCKET_MAX_BYTES))
}

fn classify_message(
    message: Message,
) -> Result<Option<ControlTransportMessage>, ControlTransportError> {
    match message {
        Message::Text(text) => {
            if text.len() > CONTROL_WIRE_MAX_BYTES {
                return Err(ControlTransportError::Protocol);
            }
            Ok(Some(ControlTransportMessage::Text(text.to_string())))
        }
        Message::Binary(_) | Message::Frame(_) => Err(ControlTransportError::Protocol),
        Message::Close(_) => Ok(Some(ControlTransportMessage::Closed)),
        Message::Ping(_) | Message::Pong(_) => Ok(None),
    }
}

fn classify_websocket_error(error: WebSocketError) -> ControlTransportError {
    match error {
        WebSocketError::Capacity(_)
        | WebSocketError::Protocol(_)
        | WebSocketError::Utf8(_)
        | WebSocketError::AttackAttempt => ControlTransportError::Protocol,
        _ => ControlTransportError::WebSocket,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_uses_exact_wss_host_path_and_device_id() {
        let device_id = "a".repeat(64);
        let request = build_request("api.alegria.by", 443, "/v1/device/connect", &device_id)
            .expect("valid request");
        assert_eq!(
            request.uri().to_string(),
            format!("wss://api.alegria.by/v1/device/connect?device_id={device_id}")
        );
        assert_eq!(
            request.headers().get(USER_AGENT),
            Some(&HeaderValue::from_static(CONTROL_USER_AGENT))
        );
    }

    #[test]
    fn websocket_configuration_is_small_and_bounded() {
        let config = websocket_config();
        assert_eq!(config.read_buffer_size, CONTROL_READ_BUFFER_BYTES);
        assert_eq!(config.write_buffer_size, 0);
        assert_eq!(config.max_write_buffer_size, CONTROL_MAX_WRITE_BUFFER_BYTES);
        assert_eq!(config.max_message_size, Some(CONTROL_WEBSOCKET_MAX_BYTES));
        assert_eq!(config.max_frame_size, Some(CONTROL_WEBSOCKET_MAX_BYTES));
        assert!(!config.accept_unmasked_frames);
        assert!(CONTROL_WEBSOCKET_MAX_BYTES > CONTROL_WIRE_MAX_BYTES);
        assert!(CONTROL_WEBSOCKET_MAX_BYTES < 8 * 1024);
    }

    #[test]
    fn application_layer_accepts_text_and_rejects_binary_and_oversize() {
        assert_eq!(
            classify_message(Message::text(r#"{"type":"READY","v":1}"#)),
            Ok(Some(ControlTransportMessage::Text(
                r#"{"type":"READY","v":1}"#.to_owned()
            )))
        );
        assert_eq!(
            classify_message(Message::binary(vec![1, 2, 3])),
            Err(ControlTransportError::Protocol)
        );
        assert_eq!(
            classify_message(Message::text("x".repeat(CONTROL_WIRE_MAX_BYTES + 1))),
            Err(ControlTransportError::Protocol)
        );
    }

    #[test]
    fn protocol_ping_pong_and_close_are_transport_mechanics_only() {
        assert_eq!(classify_message(Message::Ping(vec![1].into())), Ok(None));
        assert_eq!(classify_message(Message::Pong(vec![1].into())), Ok(None));
        assert_eq!(
            classify_message(Message::Close(None)),
            Ok(Some(ControlTransportMessage::Closed))
        );
    }
}
