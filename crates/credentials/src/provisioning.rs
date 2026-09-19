use std::{fmt, str};

use crate::proto::{
    ProtoReader, WIRE_LENGTH_DELIMITED, WIRE_VARINT, write_bytes_field, write_varint_field,
};
use crate::{ExternalCredentialError, ExternalCredentialState, ExternalCredentialStatus};

pub const PROVISIONING_SCHEMA_VERSION: u32 = 1;
pub const PROVISIONING_CHALLENGE_BYTES: usize = 32;

#[derive(Clone, PartialEq, Eq)]
pub struct ExternalProxyProvisioningEnvelope {
    credential_version: u64,
    credential_id: String,
    challenge: Vec<u8>,
    username: String,
    password: String,
}

impl ExternalProxyProvisioningEnvelope {
    pub const fn credential_version(&self) -> u64 {
        self.credential_version
    }

    pub fn credential_id(&self) -> &str {
        &self.credential_id
    }

    pub fn challenge(&self) -> &[u8] {
        &self.challenge
    }

    pub fn username(&self) -> &str {
        &self.username
    }

    pub fn password(&self) -> &str {
        &self.password
    }
}

impl fmt::Debug for ExternalProxyProvisioningEnvelope {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ExternalProxyProvisioningEnvelope")
            .field("credential_version", &self.credential_version)
            .field("credential_id", &self.credential_id)
            .field("challenge", &"<redacted>")
            .field("username", &"<redacted>")
            .field("password", &"<redacted>")
            .finish()
    }
}

pub fn encode_provisioning_envelope(
    state: ExternalCredentialState,
    challenge: &[u8],
    username: &str,
    password: &str,
) -> Result<Vec<u8>, ExternalCredentialError> {
    validate_material(state, challenge, username, password)?;

    let credential_id = state.credential_id();
    let mut encoded = Vec::with_capacity(160);
    write_varint_field(&mut encoded, 1, u64::from(PROVISIONING_SCHEMA_VERSION));
    write_varint_field(&mut encoded, 2, state.version());
    write_bytes_field(&mut encoded, 3, credential_id.as_bytes());
    write_bytes_field(&mut encoded, 4, challenge);
    write_bytes_field(&mut encoded, 5, username.as_bytes());
    write_bytes_field(&mut encoded, 6, password.as_bytes());
    Ok(encoded)
}

pub fn decode_provisioning_envelope(
    encoded: &[u8],
) -> Result<ExternalProxyProvisioningEnvelope, ExternalCredentialError> {
    let mut reader = ProtoReader::new(encoded);
    let mut schema_version = None;
    let mut credential_version = None;
    let mut credential_id = None;
    let mut challenge = None;
    let mut username = None;
    let mut password = None;

    while !reader.exhausted() {
        let tag = reader.read_tag().map_err(|_| ExternalCredentialError::InvalidProvisioningEnvelope)?;
        match tag.field_number {
            1 => {
                if tag.wire_type != WIRE_VARINT || schema_version.is_some() {
                    return Err(ExternalCredentialError::InvalidProvisioningEnvelope);
                }
                schema_version = Some(reader.read_varint().map_err(|_| ExternalCredentialError::InvalidProvisioningEnvelope)?);
            }
            2 => {
                if tag.wire_type != WIRE_VARINT || credential_version.is_some() {
                    return Err(ExternalCredentialError::InvalidProvisioningEnvelope);
                }
                credential_version = Some(reader.read_varint().map_err(|_| ExternalCredentialError::InvalidProvisioningEnvelope)?);
            }
            3 => {
                if tag.wire_type != WIRE_LENGTH_DELIMITED || credential_id.is_some() {
                    return Err(ExternalCredentialError::InvalidProvisioningEnvelope);
                }
                credential_id = Some(read_utf8(&mut reader)?);
            }
            4 => {
                if tag.wire_type != WIRE_LENGTH_DELIMITED || challenge.is_some() {
                    return Err(ExternalCredentialError::InvalidProvisioningEnvelope);
                }
                challenge = Some(reader.read_bytes().map_err(|_| ExternalCredentialError::InvalidProvisioningEnvelope)?.to_vec());
            }
            5 => {
                if tag.wire_type != WIRE_LENGTH_DELIMITED || username.is_some() {
                    return Err(ExternalCredentialError::InvalidProvisioningEnvelope);
                }
                username = Some(read_utf8(&mut reader)?);
            }
            6 => {
                if tag.wire_type != WIRE_LENGTH_DELIMITED || password.is_some() {
                    return Err(ExternalCredentialError::InvalidProvisioningEnvelope);
                }
                password = Some(read_utf8(&mut reader)?);
            }
            _ => reader.skip(tag.wire_type).map_err(|_| ExternalCredentialError::InvalidProvisioningEnvelope)?,
        }
    }

    if schema_version != Some(u64::from(PROVISIONING_SCHEMA_VERSION)) {
        return Err(ExternalCredentialError::InvalidProvisioningEnvelope);
    }
    let version =
        credential_version.ok_or(ExternalCredentialError::InvalidProvisioningEnvelope)?;
    let state = ExternalCredentialState::new(version, ExternalCredentialStatus::Active)
        .map_err(|_| ExternalCredentialError::InvalidProvisioningEnvelope)?;
    let credential_id =
        credential_id.ok_or(ExternalCredentialError::InvalidProvisioningEnvelope)?;
    let challenge = challenge.ok_or(ExternalCredentialError::InvalidProvisioningEnvelope)?;
    let username = username.ok_or(ExternalCredentialError::InvalidProvisioningEnvelope)?;
    let password = password.ok_or(ExternalCredentialError::InvalidProvisioningEnvelope)?;

    if credential_id != state.credential_id() {
        return Err(ExternalCredentialError::InvalidProvisioningEnvelope);
    }
    validate_material(state, &challenge, &username, &password)?;

    Ok(ExternalProxyProvisioningEnvelope {
        credential_version: version,
        credential_id,
        challenge,
        username,
        password,
    })
}

fn read_utf8(reader: &mut ProtoReader<'_>) -> Result<String, ExternalCredentialError> {
    let bytes = reader.read_bytes().map_err(|_| ExternalCredentialError::InvalidProvisioningEnvelope)?;
    Ok(str::from_utf8(bytes)
        .map_err(|_| ExternalCredentialError::InvalidProvisioningEnvelope)?
        .to_owned())
}

fn validate_material(
    state: ExternalCredentialState,
    challenge: &[u8],
    username: &str,
    password: &str,
) -> Result<(), ExternalCredentialError> {
    if state.status() != ExternalCredentialStatus::Active
        || challenge.len() != PROVISIONING_CHALLENGE_BYTES
        || !valid_username(username)
        || !valid_lower_hex(password, 64)
    {
        return Err(ExternalCredentialError::InvalidProvisioningEnvelope);
    }
    Ok(())
}

fn valid_username(username: &str) -> bool {
    username
        .strip_prefix("mish-")
        .is_some_and(|suffix| valid_lower_hex(suffix, 32))
}

fn valid_lower_hex(value: &str, expected_len: usize) -> bool {
    value.len() == expected_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provisioning_contract_round_trips_and_redacts() {
        let state = ExternalCredentialState::new(7, ExternalCredentialStatus::Active)
            .expect("state");
        let challenge = [9; PROVISIONING_CHALLENGE_BYTES];
        let username = "mish-0123456789abcdef0123456789abcdef";
        let password =
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

        let encoded =
            encode_provisioning_envelope(state, &challenge, username, password).expect("encode");
        let decoded = decode_provisioning_envelope(&encoded).expect("decode");

        assert_eq!(decoded.credential_version(), 7);
        assert_eq!(decoded.credential_id(), "external-proxy-v7");
        assert_eq!(decoded.challenge(), challenge);
        assert_eq!(decoded.username(), username);
        assert_eq!(decoded.password(), password);

        let debug = format!("{decoded:?}");
        assert!(!debug.contains(username));
        assert!(!debug.contains(password));
    }

    #[test]
    fn provisioning_rejects_invalid_contract_fields() {
        let state = ExternalCredentialState::initial();
        assert_eq!(
            encode_provisioning_envelope(
                state,
                &[0; PROVISIONING_CHALLENGE_BYTES - 1],
                "mish-0123456789abcdef0123456789abcdef",
                "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            ),
            Err(ExternalCredentialError::InvalidProvisioningEnvelope)
        );
        assert_eq!(
            encode_provisioning_envelope(
                state,
                &[0; PROVISIONING_CHALLENGE_BYTES],
                "bad-user",
                "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            ),
            Err(ExternalCredentialError::InvalidProvisioningEnvelope)
        );
        assert_eq!(
            decode_provisioning_envelope(&[0x08, 0x02]),
            Err(ExternalCredentialError::InvalidProvisioningEnvelope)
        );
    }
}
