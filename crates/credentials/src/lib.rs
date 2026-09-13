//! Credentials / Secrets natural-owner capability.
//!
//! Owns durable external proxy credential lifecycle semantics. Platform adapters may protect a
//! non-exportable root key and persist the non-secret owner state, but they do not own version,
//! rotation, revocation, derivation domains, or secret formatting.
//!
//! Secret values must never be projected into logs, metrics, UI, crash reports, evidence, or
//! ordinary durable configuration.

use std::{error::Error, fmt};

pub const DERIVATION_OUTPUT_BYTES: usize = 32;

const INITIAL_VERSION: u64 = 1;
const USERNAME_CONTEXT_DOMAIN: &[u8] = b"mish/external-proxy/username/v1";
const PASSWORD_CONTEXT_DOMAIN: &[u8] = b"mish/external-proxy/password/v1";
const HEX: &[u8; 16] = b"0123456789abcdef";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExternalCredentialStatus {
    Active,
    Revoked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExternalCredentialPurpose {
    Username,
    Password,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExternalCredentialState {
    version: u64,
    status: ExternalCredentialStatus,
}

impl ExternalCredentialState {
    pub fn new(
        version: u64,
        status: ExternalCredentialStatus,
    ) -> Result<Self, ExternalCredentialError> {
        if version == 0 {
            return Err(ExternalCredentialError::InvalidVersion);
        }
        Ok(Self { version, status })
    }

    pub const fn initial() -> Self {
        Self {
            version: INITIAL_VERSION,
            status: ExternalCredentialStatus::Active,
        }
    }

    pub const fn version(self) -> u64 {
        self.version
    }

    pub const fn status(self) -> ExternalCredentialStatus {
        self.status
    }

    pub fn credential_id(self) -> String {
        format!("external-proxy-v{}", self.version)
    }

    /// Rotation always creates one strictly newer active credential version. Rotating a revoked
    /// state is the explicit re-provisioning operation; the revoked version never becomes active
    /// again.
    pub fn rotate(self) -> Result<Self, ExternalCredentialError> {
        let version = self
            .version
            .checked_add(1)
            .ok_or(ExternalCredentialError::VersionExhausted)?;
        Ok(Self {
            version,
            status: ExternalCredentialStatus::Active,
        })
    }

    /// Revocation is idempotent for the exact version and never changes its version identity.
    pub const fn revoke(self) -> Self {
        Self {
            version: self.version,
            status: ExternalCredentialStatus::Revoked,
        }
    }

    /// Returns a domain-separated input for the platform HMAC root key. The root key itself is
    /// never accepted by this capability and therefore cannot be exported across the adapter.
    pub fn derivation_context(
        self,
        purpose: ExternalCredentialPurpose,
    ) -> Result<Vec<u8>, ExternalCredentialError> {
        self.require_active()?;
        let domain = match purpose {
            ExternalCredentialPurpose::Username => USERNAME_CONTEXT_DOMAIN,
            ExternalCredentialPurpose::Password => PASSWORD_CONTEXT_DOMAIN,
        };
        let mut context = Vec::with_capacity(domain.len() + u64::BITS as usize / 8);
        context.extend_from_slice(domain);
        context.extend_from_slice(&self.version.to_be_bytes());
        Ok(context)
    }

    /// Converts exact HMAC-SHA-256 outputs into proxy protocol material. The adapter supplies only
    /// derived outputs, never the non-exportable root. Revoked states cannot materialize secrets.
    pub fn materialize(
        self,
        username_mac: &[u8],
        password_mac: &[u8],
    ) -> Result<ExternalCredentialMaterial, ExternalCredentialError> {
        self.require_active()?;
        if username_mac.len() != DERIVATION_OUTPUT_BYTES
            || password_mac.len() != DERIVATION_OUTPUT_BYTES
        {
            return Err(ExternalCredentialError::InvalidDerivationOutput);
        }

        let username = format!("mish-{}", encode_hex(&username_mac[..16]));
        let password = encode_hex(password_mac);
        Ok(ExternalCredentialMaterial { username, password })
    }

    fn require_active(self) -> Result<(), ExternalCredentialError> {
        match self.status {
            ExternalCredentialStatus::Active => Ok(()),
            ExternalCredentialStatus::Revoked => Err(ExternalCredentialError::Revoked),
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct ExternalCredentialMaterial {
    username: String,
    password: String,
}

impl ExternalCredentialMaterial {
    pub fn username(&self) -> &str {
        &self.username
    }

    pub fn password(&self) -> &str {
        &self.password
    }
}

impl fmt::Debug for ExternalCredentialMaterial {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ExternalCredentialMaterial")
            .field("username", &"<redacted>")
            .field("password", &"<redacted>")
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExternalCredentialError {
    InvalidVersion,
    VersionExhausted,
    Revoked,
    InvalidDerivationOutput,
}

impl fmt::Display for ExternalCredentialError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidVersion => "external credential version must be non-zero",
            Self::VersionExhausted => "external credential version space is exhausted",
            Self::Revoked => "external credential version is revoked",
            Self::InvalidDerivationOutput => "external credential derivation output is invalid",
        })
    }
}

impl Error for ExternalCredentialError {}

fn encode_hex(bytes: &[u8]) -> String {
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(HEX[(byte >> 4) as usize] as char);
        encoded.push(HEX[(byte & 0x0f) as usize] as char);
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_state_is_active_and_stable() {
        let state = ExternalCredentialState::initial();
        assert_eq!(state.version(), 1);
        assert_eq!(state.status(), ExternalCredentialStatus::Active);
        assert_eq!(state.credential_id(), "external-proxy-v1");
    }

    #[test]
    fn invalid_persisted_version_is_rejected() {
        assert_eq!(
            ExternalCredentialState::new(0, ExternalCredentialStatus::Active),
            Err(ExternalCredentialError::InvalidVersion)
        );
    }

    #[test]
    fn derivation_domains_are_stable_and_distinct() {
        let state = ExternalCredentialState::initial();
        let username = state
            .derivation_context(ExternalCredentialPurpose::Username)
            .expect("active username context");
        let password = state
            .derivation_context(ExternalCredentialPurpose::Password)
            .expect("active password context");
        assert_ne!(username, password);
        assert!(username.starts_with(USERNAME_CONTEXT_DOMAIN));
        assert!(password.starts_with(PASSWORD_CONTEXT_DOMAIN));
        assert!(username.ends_with(&1_u64.to_be_bytes()));
        assert!(password.ends_with(&1_u64.to_be_bytes()));
    }

    #[test]
    fn rotation_changes_version_and_derivation_without_reactivating_old_version() {
        let first = ExternalCredentialState::initial();
        let second = first.rotate().expect("rotate");
        assert_eq!(second.version(), 2);
        assert_eq!(second.status(), ExternalCredentialStatus::Active);
        assert_ne!(
            first
                .derivation_context(ExternalCredentialPurpose::Password)
                .expect("first context"),
            second
                .derivation_context(ExternalCredentialPurpose::Password)
                .expect("second context")
        );
        assert_eq!(first.version(), 1);
    }

    #[test]
    fn revocation_is_idempotent_and_blocks_derivation_and_materialization() {
        let revoked = ExternalCredentialState::initial().revoke().revoke();
        assert_eq!(revoked.version(), 1);
        assert_eq!(revoked.status(), ExternalCredentialStatus::Revoked);
        assert_eq!(
            revoked.derivation_context(ExternalCredentialPurpose::Username),
            Err(ExternalCredentialError::Revoked)
        );
        assert_eq!(
            revoked.materialize(&[1; DERIVATION_OUTPUT_BYTES], &[2; DERIVATION_OUTPUT_BYTES]),
            Err(ExternalCredentialError::Revoked)
        );
    }

    #[test]
    fn rotation_after_revocation_issues_a_new_active_version() {
        let next = ExternalCredentialState::initial()
            .revoke()
            .rotate()
            .expect("re-provision by rotation");
        assert_eq!(next.version(), 2);
        assert_eq!(next.status(), ExternalCredentialStatus::Active);
    }

    #[test]
    fn materialization_requires_exact_hmac_sha256_outputs() {
        let state = ExternalCredentialState::initial();
        assert_eq!(
            state.materialize(
                &[1; DERIVATION_OUTPUT_BYTES - 1],
                &[2; DERIVATION_OUTPUT_BYTES]
            ),
            Err(ExternalCredentialError::InvalidDerivationOutput)
        );
        let material = state
            .materialize(&[1; DERIVATION_OUTPUT_BYTES], &[2; DERIVATION_OUTPUT_BYTES])
            .expect("exact outputs");
        assert!(material.username().starts_with("mish-"));
        assert_eq!(material.username().len(), 5 + 32);
        assert_eq!(material.password().len(), 64);
        assert!(!format!("{material:?}").contains(material.username()));
        assert!(!format!("{material:?}").contains(material.password()));
    }

    #[test]
    fn version_exhaustion_fails_closed() {
        let state = ExternalCredentialState::new(u64::MAX, ExternalCredentialStatus::Active)
            .expect("max version is representable");
        assert_eq!(
            state.rotate(),
            Err(ExternalCredentialError::VersionExhausted)
        );
    }
}
