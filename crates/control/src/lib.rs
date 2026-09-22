//! Authenticated remote-control protocol natural-owner capability.
//!
//! This crate owns the narrow v1 wire/auth vocabulary for MISH-initiated control sessions.
//! It owns no socket, scheduler, Android Keystore effect, Cloudflare implementation or rotation
//! mutation. The only v1 command is ROTATE_IP.

use ring::{digest, rand};
use serde::{Deserialize, Serialize};
use std::fmt;

pub const CONTROL_PROTOCOL_VERSION: u8 = 1;
pub const CONTROL_AUTH_DOMAIN: &str = "MISH_CONTROL_AUTH_V1";
pub const CONTROL_DEVICE_ID_HEX_BYTES: usize = 64;
pub const CONTROL_NONCE_B64URL_BYTES: usize = 43;
pub const CONTROL_REQUEST_ID_MAX_BYTES: usize = 64;
pub const CONTROL_WIRE_MAX_BYTES: usize = 2_048;
pub const CONTROL_PUBLIC_SPKI_MAX_BYTES: usize = 512;
pub const CONTROL_SIGNATURE_P1363_BYTES: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlDeviceIdentity {
    device_id: String,
    public_key_spki: Vec<u8>,
}

impl ControlDeviceIdentity {
    pub fn from_public_key_spki(public_key_spki: Vec<u8>) -> Result<Self, ControlProtocolError> {
        if public_key_spki.is_empty() || public_key_spki.len() > CONTROL_PUBLIC_SPKI_MAX_BYTES {
            return Err(ControlProtocolError::InvalidPublicKey);
        }
        let digest = digest::digest(&digest::SHA256, &public_key_spki);
        let device_id = encode_hex(digest.as_ref());
        debug_assert_eq!(device_id.len(), CONTROL_DEVICE_ID_HEX_BYTES);
        Ok(Self {
            device_id,
            public_key_spki,
        })
    }

    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    pub fn public_key_spki(&self) -> &[u8] {
        &self.public_key_spki
    }

    pub fn public_key_spki_b64(&self) -> String {
        encode_base64(&self.public_key_spki, false, true)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerControlMessage {
    Challenge { nonce: String },
    Ready,
    RotateIp { request_id: String },
    ResultAck { request_id: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteRotationResult {
    Changed,
    Unchanged,
    Failed,
    Rejected,
}

impl RemoteRotationResult {
    pub const fn code(self) -> &'static str {
        match self {
            Self::Changed => "CHANGED",
            Self::Unchanged => "UNCHANGED",
            Self::Failed => "FAILED",
            Self::Rejected => "REJECTED",
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
enum WireServerMessage {
    #[serde(rename = "CHALLENGE")]
    Challenge { v: u8, nonce: String },
    #[serde(rename = "READY")]
    Ready { v: u8 },
    #[serde(rename = "ROTATE_IP")]
    RotateIp { v: u8, request_id: String },
    #[serde(rename = "RESULT_ACK")]
    ResultAck { v: u8, request_id: String },
}

#[derive(Debug, Serialize)]
struct WireAuth<'a> {
    v: u8,
    #[serde(rename = "type")]
    message_type: &'static str,
    device_id: &'a str,
    signature: &'a str,
}

#[derive(Debug, Serialize)]
struct WireAccepted<'a> {
    v: u8,
    #[serde(rename = "type")]
    message_type: &'static str,
    request_id: &'a str,
}

#[derive(Debug, Serialize)]
struct WireResult<'a> {
    v: u8,
    #[serde(rename = "type")]
    message_type: &'static str,
    request_id: &'a str,
    result: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    operation_id: Option<u64>,
}

pub fn parse_server_message(raw: &str) -> Result<ServerControlMessage, ControlProtocolError> {
    validate_wire_text(raw)?;
    let message: WireServerMessage =
        serde_json::from_str(raw).map_err(|_| ControlProtocolError::MalformedWireMessage)?;
    match message {
        WireServerMessage::Challenge { v, nonce } => {
            require_version(v)?;
            validate_nonce(&nonce)?;
            Ok(ServerControlMessage::Challenge { nonce })
        }
        WireServerMessage::Ready { v } => {
            require_version(v)?;
            Ok(ServerControlMessage::Ready)
        }
        WireServerMessage::RotateIp { v, request_id } => {
            require_version(v)?;
            validate_request_id(&request_id)?;
            Ok(ServerControlMessage::RotateIp { request_id })
        }
        WireServerMessage::ResultAck { v, request_id } => {
            require_version(v)?;
            validate_request_id(&request_id)?;
            Ok(ServerControlMessage::ResultAck { request_id })
        }
    }
}

pub fn canonical_auth_payload(
    device_id: &str,
    nonce: &str,
) -> Result<Vec<u8>, ControlProtocolError> {
    validate_device_id(device_id)?;
    validate_nonce(nonce)?;
    Ok(format!("{CONTROL_AUTH_DOMAIN}\n{device_id}\n{nonce}").into_bytes())
}

pub fn encode_auth_message(
    device_id: &str,
    signature_p1363_b64url: &str,
) -> Result<String, ControlProtocolError> {
    validate_device_id(device_id)?;
    validate_b64url(signature_p1363_b64url, 86)?;
    encode_wire(&WireAuth {
        v: CONTROL_PROTOCOL_VERSION,
        message_type: "AUTH",
        device_id,
        signature: signature_p1363_b64url,
    })
}

pub fn encode_accepted_message(request_id: &str) -> Result<String, ControlProtocolError> {
    validate_request_id(request_id)?;
    encode_wire(&WireAccepted {
        v: CONTROL_PROTOCOL_VERSION,
        message_type: "ACCEPTED",
        request_id,
    })
}

pub fn encode_result_message(
    request_id: &str,
    result: RemoteRotationResult,
    operation_id: Option<u64>,
) -> Result<String, ControlProtocolError> {
    validate_request_id(request_id)?;
    if operation_id == Some(0) {
        return Err(ControlProtocolError::InvalidOperationId);
    }
    encode_wire(&WireResult {
        v: CONTROL_PROTOCOL_VERSION,
        message_type: "RESULT",
        request_id,
        result: result.code(),
        operation_id,
    })
}

pub fn validate_request_id(request_id: &str) -> Result<(), ControlProtocolError> {
    if request_id.is_empty()
        || request_id.len() > CONTROL_REQUEST_ID_MAX_BYTES
        || !request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(ControlProtocolError::InvalidRequestId);
    }
    Ok(())
}

pub fn p256_der_signature_to_p1363_b64url(
    der: &[u8],
) -> Result<String, ControlProtocolError> {
    let signature = p256_der_signature_to_p1363(der)?;
    Ok(encode_base64(&signature, true, false))
}

pub fn websocket_client_key() -> Result<String, ControlProtocolError> {
    let mut random_key = [0_u8; 16];
    rand::SecureRandom::fill(&rand::SystemRandom::new(), &mut random_key)
        .map_err(|_| ControlProtocolError::RandomUnavailable)?;
    Ok(encode_base64(&random_key, false, true))
}

pub fn websocket_expected_accept(client_key: &str) -> Result<String, ControlProtocolError> {
    if client_key.is_empty() || client_key.len() > 64 || !client_key.is_ascii() {
        return Err(ControlProtocolError::MalformedWebSocketHandshake);
    }
    let mut input = Vec::with_capacity(client_key.len() + 36);
    input.extend_from_slice(client_key.as_bytes());
    input.extend_from_slice(b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    let value = digest::digest(&digest::SHA1_FOR_LEGACY_USE_ONLY, &input);
    Ok(encode_base64(value.as_ref(), false, true))
}

fn encode_wire<T: Serialize>(message: &T) -> Result<String, ControlProtocolError> {
    let encoded =
        serde_json::to_string(message).map_err(|_| ControlProtocolError::MalformedWireMessage)?;
    if encoded.len() > CONTROL_WIRE_MAX_BYTES {
        return Err(ControlProtocolError::WireMessageTooLarge);
    }
    Ok(encoded)
}

fn validate_wire_text(raw: &str) -> Result<(), ControlProtocolError> {
    if raw.is_empty()
        || raw.len() > CONTROL_WIRE_MAX_BYTES
        || raw.trim() != raw
        || raw.bytes().any(|byte| byte == 0)
    {
        return Err(ControlProtocolError::MalformedWireMessage);
    }
    Ok(())
}

fn require_version(version: u8) -> Result<(), ControlProtocolError> {
    if version == CONTROL_PROTOCOL_VERSION {
        Ok(())
    } else {
        Err(ControlProtocolError::UnsupportedVersion)
    }
}

fn validate_device_id(device_id: &str) -> Result<(), ControlProtocolError> {
    if device_id.len() == CONTROL_DEVICE_ID_HEX_BYTES
        && device_id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        Ok(())
    } else {
        Err(ControlProtocolError::InvalidDeviceId)
    }
}

fn validate_nonce(nonce: &str) -> Result<(), ControlProtocolError> {
    validate_b64url(nonce, CONTROL_NONCE_B64URL_BYTES)
}

fn validate_b64url(value: &str, exact_len: usize) -> Result<(), ControlProtocolError> {
    if value.len() == exact_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        Ok(())
    } else {
        Err(ControlProtocolError::InvalidBase64Url)
    }
}

fn p256_der_signature_to_p1363(
    der: &[u8],
) -> Result<[u8; CONTROL_SIGNATURE_P1363_BYTES], ControlProtocolError> {
    let mut cursor = 0_usize;
    if take_byte(der, &mut cursor)? != 0x30 {
        return Err(ControlProtocolError::InvalidSignature);
    }
    let sequence_len = take_der_length(der, &mut cursor)?;
    if cursor.checked_add(sequence_len) != Some(der.len()) {
        return Err(ControlProtocolError::InvalidSignature);
    }

    let r = take_der_integer(der, &mut cursor)?;
    let s = take_der_integer(der, &mut cursor)?;
    if cursor != der.len() {
        return Err(ControlProtocolError::InvalidSignature);
    }

    let mut signature = [0_u8; CONTROL_SIGNATURE_P1363_BYTES];
    copy_integer_32(r, &mut signature[..32])?;
    copy_integer_32(s, &mut signature[32..])?;
    Ok(signature)
}

fn take_der_integer<'a>(
    der: &'a [u8],
    cursor: &mut usize,
) -> Result<&'a [u8], ControlProtocolError> {
    if take_byte(der, cursor)? != 0x02 {
        return Err(ControlProtocolError::InvalidSignature);
    }
    let len = take_der_length(der, cursor)?;
    let end = cursor
        .checked_add(len)
        .filter(|end| *end <= der.len())
        .ok_or(ControlProtocolError::InvalidSignature)?;
    let value = &der[*cursor..end];
    *cursor = end;
    if value.is_empty() || value[0] & 0x80 != 0 {
        return Err(ControlProtocolError::InvalidSignature);
    }
    if value.len() > 1 && value[0] == 0 && value[1] & 0x80 == 0 {
        return Err(ControlProtocolError::InvalidSignature);
    }
    Ok(value)
}

fn copy_integer_32(value: &[u8], output: &mut [u8]) -> Result<(), ControlProtocolError> {
    let value = if value.first() == Some(&0) {
        &value[1..]
    } else {
        value
    };
    if value.is_empty() || value.len() > 32 || output.len() != 32 {
        return Err(ControlProtocolError::InvalidSignature);
    }
    let offset = 32 - value.len();
    output[offset..].copy_from_slice(value);
    Ok(())
}

fn take_der_length(der: &[u8], cursor: &mut usize) -> Result<usize, ControlProtocolError> {
    let first = take_byte(der, cursor)?;
    if first & 0x80 == 0 {
        return Ok(usize::from(first));
    }
    let bytes = usize::from(first & 0x7f);
    if bytes == 0 || bytes > 2 {
        return Err(ControlProtocolError::InvalidSignature);
    }
    let mut length = 0_usize;
    for _ in 0..bytes {
        length = length
            .checked_mul(256)
            .and_then(|value| value.checked_add(usize::from(take_byte(der, cursor).ok()?)))
            .ok_or(ControlProtocolError::InvalidSignature)?;
    }
    if length < 128 {
        return Err(ControlProtocolError::InvalidSignature);
    }
    Ok(length)
}

fn take_byte(der: &[u8], cursor: &mut usize) -> Result<u8, ControlProtocolError> {
    let byte = *der
        .get(*cursor)
        .ok_or(ControlProtocolError::InvalidSignature)?;
    *cursor = cursor
        .checked_add(1)
        .ok_or(ControlProtocolError::InvalidSignature)?;
    Ok(byte)
}

fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(HEX[(byte >> 4) as usize] as char);
        encoded.push(HEX[(byte & 0x0f) as usize] as char);
    }
    encoded
}

fn encode_base64(bytes: &[u8], url_safe: bool, padding: bool) -> String {
    const STANDARD: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const URL_SAFE: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let alphabet = if url_safe { URL_SAFE } else { STANDARD };
    let capacity = bytes.len().div_ceil(3) * 4;
    let mut out = String::with_capacity(capacity);

    for chunk in bytes.chunks(3) {
        let a = chunk[0];
        let b = *chunk.get(1).unwrap_or(&0);
        let c = *chunk.get(2).unwrap_or(&0);
        out.push(alphabet[usize::from(a >> 2)] as char);
        out.push(alphabet[usize::from(((a & 0x03) << 4) | (b >> 4))] as char);
        if chunk.len() > 1 {
            out.push(alphabet[usize::from(((b & 0x0f) << 2) | (c >> 6))] as char);
        } else if padding {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(alphabet[usize::from(c & 0x3f)] as char);
        } else if padding {
            out.push('=');
        }
    }
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlProtocolError {
    UnsupportedVersion,
    InvalidPublicKey,
    InvalidDeviceId,
    InvalidBase64Url,
    InvalidRequestId,
    InvalidOperationId,
    InvalidSignature,
    MalformedWireMessage,
    WireMessageTooLarge,
    MalformedWebSocketHandshake,
    RandomUnavailable,
}

impl fmt::Display for ControlProtocolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::UnsupportedVersion => "control protocol version is unsupported",
            Self::InvalidPublicKey => "control public key is invalid",
            Self::InvalidDeviceId => "control device id is invalid",
            Self::InvalidBase64Url => "control base64url field is invalid",
            Self::InvalidRequestId => "control request id is invalid",
            Self::InvalidOperationId => "control operation id is invalid",
            Self::InvalidSignature => "control ECDSA signature encoding is invalid",
            Self::MalformedWireMessage => "control wire message is malformed",
            Self::WireMessageTooLarge => "control wire message exceeds the bounded size",
            Self::MalformedWebSocketHandshake => "control WebSocket handshake is malformed",
            Self::RandomUnavailable => "secure random source is unavailable",
        })
    }
}

impl std::error::Error for ControlProtocolError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_is_stable_sha256_of_spki() {
        let identity = ControlDeviceIdentity::from_public_key_spki(vec![1, 2, 3, 4]).unwrap();
        assert_eq!(
            identity.device_id(),
            "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a"
        );
        assert_eq!(identity.public_key_spki_b64(), "AQIDBA==");
    }

    #[test]
    fn auth_payload_is_canonical_and_bounded() {
        let device = "a".repeat(64);
        let nonce = "b".repeat(43);
        let payload = canonical_auth_payload(&device, &nonce).unwrap();
        assert_eq!(
            String::from_utf8(payload).unwrap(),
            format!("{CONTROL_AUTH_DOMAIN}\n{device}\n{nonce}")
        );
        assert!(canonical_auth_payload("A".repeat(64).as_str(), &nonce).is_err());
    }

    #[test]
    fn strict_server_messages_accept_only_v1_known_shapes() {
        assert_eq!(
            parse_server_message(
                r#"{"type":"CHALLENGE","v":1,"nonce":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
            ),
            Ok(ServerControlMessage::Challenge {
                nonce: "a".repeat(43)
            })
        );
        assert_eq!(
            parse_server_message(r#"{"type":"READY","v":1}"#),
            Ok(ServerControlMessage::Ready)
        );
        assert_eq!(
            parse_server_message(r#"{"type":"ROTATE_IP","v":1,"request_id":"req_1"}"#),
            Ok(ServerControlMessage::RotateIp {
                request_id: "req_1".to_owned()
            })
        );
        assert!(parse_server_message(r#"{"type":"SHELL","v":1}"#).is_err());
        assert!(parse_server_message(r#"{"type":"READY","v":2}"#).is_err());
        assert!(parse_server_message(r#" {"type":"READY","v":1}"#).is_err());
    }

    #[test]
    fn device_wire_never_contains_ip_or_secret_fields() {
        let device = "a".repeat(64);
        let signature = "b".repeat(86);
        let auth = encode_auth_message(&device, &signature).unwrap();
        assert!(auth.contains(r#""type":"AUTH""#));
        let accepted = encode_accepted_message("req_1").unwrap();
        assert_eq!(accepted, r#"{"v":1,"type":"ACCEPTED","request_id":"req_1"}"#);
        let result =
            encode_result_message("req_1", RemoteRotationResult::Changed, Some(7)).unwrap();
        assert_eq!(
            result,
            r#"{"v":1,"type":"RESULT","request_id":"req_1","result":"CHANGED","operation_id":7}"#
        );
        for message in [auth, accepted, result] {
            assert!(!message.contains("before_ip"));
            assert!(!message.contains("after_ip"));
            assert!(!message.contains("password"));
        }
    }

    #[test]
    fn der_ecdsa_is_converted_to_fixed_p1363_base64url() {
        let mut der = vec![0x30, 0x44, 0x02, 0x20];
        der.extend(1_u8..=32);
        der.extend([0x02, 0x20]);
        der.extend(33_u8..=64);
        let encoded = p256_der_signature_to_p1363_b64url(&der).unwrap();
        assert_eq!(encoded.len(), 86);
        assert!(!encoded.contains('='));

        let bad = [0x30, 0x03, 0x02, 0x01, 0x80];
        assert_eq!(
            p256_der_signature_to_p1363_b64url(&bad),
            Err(ControlProtocolError::InvalidSignature)
        );
    }

    #[test]
    fn websocket_accept_matches_rfc6455_fixture() {
        assert_eq!(
            websocket_expected_accept("dGhlIHNhbXBsZSBub25jZQ==").unwrap(),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        );
    }

    #[test]
    fn request_ids_are_narrow_and_injection_safe() {
        for valid in ["a", "req_123", "ABC-def", &"x".repeat(64)] {
            assert!(validate_request_id(valid).is_ok());
        }
        for invalid in ["", "has space", "x/y", "x\ny", &"x".repeat(65)] {
            assert!(validate_request_id(invalid).is_err());
        }
    }
}
