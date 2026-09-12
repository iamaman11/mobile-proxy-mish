use mish_credentials::{
    ExternalCredentialError as OwnerCredentialError,
    ExternalCredentialPurpose as OwnerCredentialPurpose,
    ExternalCredentialState as OwnerCredentialState,
    ExternalCredentialStatus as OwnerCredentialStatus,
};
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExternalCredentialStateView {
    pub version: u64,
    pub revoked: bool,
    pub credential_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExternalCredentialDerivationView {
    pub version: u64,
    pub credential_id: String,
    pub username_context: Vec<u8>,
    pub password_context: Vec<u8>,
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExternalProxyCredentialMaterial {
    pub username: String,
    pub password: String,
}

impl fmt::Debug for ExternalProxyCredentialMaterial {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ExternalProxyCredentialMaterial")
            .field("username", &"<redacted>")
            .field("password", &"<redacted>")
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum ExternalCredentialBoundaryError {
    InvalidState,
    VersionExhausted,
    Revoked,
    InvalidDerivationOutput,
}

impl fmt::Display for ExternalCredentialBoundaryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidState => "external credential state is invalid",
            Self::VersionExhausted => "external credential version space is exhausted",
            Self::Revoked => "external credential version is revoked",
            Self::InvalidDerivationOutput => "external credential derivation output is invalid",
        })
    }
}

impl std::error::Error for ExternalCredentialBoundaryError {}

#[uniffi::export]
pub fn external_credential_initial_state() -> ExternalCredentialStateView {
    map_state(OwnerCredentialState::initial())
}

#[uniffi::export]
pub fn external_credential_restore(
    version: u64,
    revoked: bool,
) -> Result<ExternalCredentialStateView, ExternalCredentialBoundaryError> {
    Ok(map_state(owner_state(version, revoked)?))
}

#[uniffi::export]
pub fn external_credential_rotate(
    version: u64,
    revoked: bool,
) -> Result<ExternalCredentialStateView, ExternalCredentialBoundaryError> {
    Ok(map_state(owner_state(version, revoked)?.rotate()?))
}

#[uniffi::export]
pub fn external_credential_revoke(
    version: u64,
    revoked: bool,
) -> Result<ExternalCredentialStateView, ExternalCredentialBoundaryError> {
    Ok(map_state(owner_state(version, revoked)?.revoke()))
}

#[uniffi::export]
pub fn external_credential_derivation(
    version: u64,
    revoked: bool,
) -> Result<ExternalCredentialDerivationView, ExternalCredentialBoundaryError> {
    let state = owner_state(version, revoked)?;
    Ok(ExternalCredentialDerivationView {
        version: state.version(),
        credential_id: state.credential_id(),
        username_context: state.derivation_context(OwnerCredentialPurpose::Username)?,
        password_context: state.derivation_context(OwnerCredentialPurpose::Password)?,
    })
}

#[uniffi::export]
pub fn external_credential_materialize(
    version: u64,
    revoked: bool,
    username_mac: Vec<u8>,
    password_mac: Vec<u8>,
) -> Result<ExternalProxyCredentialMaterial, ExternalCredentialBoundaryError> {
    let material = owner_state(version, revoked)?.materialize(&username_mac, &password_mac)?;
    Ok(ExternalProxyCredentialMaterial {
        username: material.username().to_owned(),
        password: material.password().to_owned(),
    })
}

fn owner_state(
    version: u64,
    revoked: bool,
) -> Result<OwnerCredentialState, ExternalCredentialBoundaryError> {
    let status = if revoked {
        OwnerCredentialStatus::Revoked
    } else {
        OwnerCredentialStatus::Active
    };
    OwnerCredentialState::new(version, status).map_err(Into::into)
}

fn map_state(state: OwnerCredentialState) -> ExternalCredentialStateView {
    ExternalCredentialStateView {
        version: state.version(),
        revoked: state.status() == OwnerCredentialStatus::Revoked,
        credential_id: state.credential_id(),
    }
}

impl From<OwnerCredentialError> for ExternalCredentialBoundaryError {
    fn from(error: OwnerCredentialError) -> Self {
        match error {
            OwnerCredentialError::InvalidVersion => Self::InvalidState,
            OwnerCredentialError::VersionExhausted => Self::VersionExhausted,
            OwnerCredentialError::Revoked => Self::Revoked,
            OwnerCredentialError::InvalidDerivationOutput => Self::InvalidDerivationOutput,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_state_round_trip_delegates_to_owner() {
        let initial = external_credential_initial_state();
        assert_eq!(initial.version, 1);
        assert!(!initial.revoked);
        let restored = external_credential_restore(initial.version, initial.revoked)
            .expect("restore initial owner state");
        assert_eq!(restored, initial);
    }

    #[test]
    fn ffi_rotation_and_revocation_preserve_owner_semantics() {
        let initial = external_credential_initial_state();
        let revoked = external_credential_revoke(initial.version, initial.revoked)
            .expect("revoke owner state");
        assert!(revoked.revoked);
        assert_eq!(
            external_credential_derivation(revoked.version, revoked.revoked),
            Err(ExternalCredentialBoundaryError::Revoked)
        );
        let rotated = external_credential_rotate(revoked.version, revoked.revoked)
            .expect("rotate revoked owner state");
        assert_eq!(rotated.version, 2);
        assert!(!rotated.revoked);
    }

    #[test]
    fn ffi_materialization_rejects_bad_hmac_length() {
        let state = external_credential_initial_state();
        assert_eq!(
            external_credential_materialize(
                state.version,
                state.revoked,
                vec![1; 31],
                vec![2; 32],
            ),
            Err(ExternalCredentialBoundaryError::InvalidDerivationOutput)
        );
    }
}
