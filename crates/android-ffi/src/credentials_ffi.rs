use mish_credentials::{
    ExternalCredentialError as OwnerCredentialError,
    ExternalCredentialPersistenceAction as OwnerPersistenceAction,
    ExternalCredentialPurpose as OwnerCredentialPurpose,
    ExternalCredentialState as OwnerCredentialState,
    ExternalCredentialStatus as OwnerCredentialStatus, encode_provisioning_envelope, encode_state,
    resolve_persistence,
};
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExternalCredentialStateView {
    pub version: u64,
    pub revoked: bool,
    pub credential_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExternalCredentialCanonicalStateView {
    pub state: ExternalCredentialStateView,
    pub canonical_state: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ExternalCredentialPersistenceActionView {
    UseCurrent,
    PersistCanonical,
    CreateRootAndPersistCanonical,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExternalCredentialPersistenceResolutionView {
    pub state: ExternalCredentialStateView,
    pub canonical_state: Vec<u8>,
    pub action: ExternalCredentialPersistenceActionView,
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
    InvalidStorage,
    VersionExhausted,
    Revoked,
    InvalidDerivationOutput,
    InvalidProvisioningEnvelope,
}

impl fmt::Display for ExternalCredentialBoundaryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidState => "external credential state is invalid",
            Self::InvalidStorage => "external credential durable storage is invalid",
            Self::VersionExhausted => "external credential version space is exhausted",
            Self::Revoked => "external credential version is revoked",
            Self::InvalidDerivationOutput => "external credential derivation output is invalid",
            Self::InvalidProvisioningEnvelope => {
                "external credential provisioning envelope is invalid"
            }
        })
    }
}

impl std::error::Error for ExternalCredentialBoundaryError {}

#[uniffi::export]
pub fn external_credential_resolve_persistence(
    canonical_state: Option<Vec<u8>>,
    legacy_version: Option<String>,
    legacy_revoked: Option<bool>,
    root_exists: bool,
) -> Result<ExternalCredentialPersistenceResolutionView, ExternalCredentialBoundaryError> {
    let resolution = resolve_persistence(
        canonical_state.as_deref(),
        legacy_version.as_deref(),
        legacy_revoked,
        root_exists,
    )?;
    Ok(ExternalCredentialPersistenceResolutionView {
        state: map_state(resolution.state()),
        canonical_state: resolution.canonical_state().to_vec(),
        action: match resolution.action() {
            OwnerPersistenceAction::UseCurrent => {
                ExternalCredentialPersistenceActionView::UseCurrent
            }
            OwnerPersistenceAction::PersistCanonical => {
                ExternalCredentialPersistenceActionView::PersistCanonical
            }
            OwnerPersistenceAction::CreateRootAndPersistCanonical => {
                ExternalCredentialPersistenceActionView::CreateRootAndPersistCanonical
            }
        },
    })
}

#[uniffi::export]
pub fn external_credential_rotate(
    version: u64,
    revoked: bool,
) -> Result<ExternalCredentialCanonicalStateView, ExternalCredentialBoundaryError> {
    Ok(map_canonical(owner_state(version, revoked)?.rotate()?))
}

#[uniffi::export]
pub fn external_credential_revoke(
    version: u64,
    revoked: bool,
) -> Result<ExternalCredentialCanonicalStateView, ExternalCredentialBoundaryError> {
    Ok(map_canonical(owner_state(version, revoked)?.revoke()))
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

#[uniffi::export]
pub fn external_credential_encode_provisioning_envelope(
    credential_version: u64,
    challenge: Vec<u8>,
    username: String,
    password: String,
) -> Result<Vec<u8>, ExternalCredentialBoundaryError> {
    let state = OwnerCredentialState::new(credential_version, OwnerCredentialStatus::Active)?;
    Ok(encode_provisioning_envelope(
        state,
        &challenge,
        &username,
        &password,
    )?)
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

fn map_canonical(state: OwnerCredentialState) -> ExternalCredentialCanonicalStateView {
    ExternalCredentialCanonicalStateView {
        state: map_state(state),
        canonical_state: encode_state(state),
    }
}

impl From<OwnerCredentialError> for ExternalCredentialBoundaryError {
    fn from(error: OwnerCredentialError) -> Self {
        match error {
            OwnerCredentialError::InvalidVersion
            | OwnerCredentialError::MalformedState
            | OwnerCredentialError::NonCanonicalState => Self::InvalidState,
            OwnerCredentialError::MixedPersistenceSchemas
            | OwnerCredentialError::IncompleteLegacyState
            | OwnerCredentialError::InvalidLegacyVersion
            | OwnerCredentialError::MissingRootForState
            | OwnerCredentialError::RootWithoutState => Self::InvalidStorage,
            OwnerCredentialError::VersionExhausted => Self::VersionExhausted,
            OwnerCredentialError::Revoked => Self::Revoked,
            OwnerCredentialError::InvalidDerivationOutput => Self::InvalidDerivationOutput,
            OwnerCredentialError::InvalidProvisioningEnvelope => {
                Self::InvalidProvisioningEnvelope
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_persistence_resolution_delegates_to_owner() {
        let initial =
            external_credential_resolve_persistence(None, None, None, false).expect("initialize");
        assert_eq!(initial.state.version, 1);
        assert!(!initial.state.revoked);
        assert_eq!(
            initial.action,
            ExternalCredentialPersistenceActionView::CreateRootAndPersistCanonical
        );

        let current = external_credential_resolve_persistence(
            Some(initial.canonical_state.clone()),
            None,
            None,
            true,
        )
        .expect("current");
        assert_eq!(current.state, initial.state);
        assert_eq!(
            current.action,
            ExternalCredentialPersistenceActionView::UseCurrent
        );
    }

    #[test]
    fn ffi_rotation_and_revocation_return_canonical_owner_state() {
        let revoked = external_credential_revoke(1, false).expect("revoke owner state");
        assert!(revoked.state.revoked);
        assert_eq!(
            external_credential_derivation(revoked.state.version, revoked.state.revoked),
            Err(ExternalCredentialBoundaryError::Revoked)
        );

        let rotated = external_credential_rotate(revoked.state.version, revoked.state.revoked)
            .expect("rotate revoked owner state");
        assert_eq!(rotated.state.version, 2);
        assert!(!rotated.state.revoked);
        assert_eq!(rotated.canonical_state, vec![0x08, 0x02]);
    }

    #[test]
    fn ffi_materialization_rejects_bad_hmac_length() {
        assert_eq!(
            external_credential_materialize(1, false, vec![1; 31], vec![2; 32]),
            Err(ExternalCredentialBoundaryError::InvalidDerivationOutput)
        );
    }

    #[test]
    fn ffi_provisioning_plaintext_is_owner_encoded() {
        let encoded = external_credential_encode_provisioning_envelope(
            7,
            vec![3; 32],
            "mish-0123456789abcdef0123456789abcdef".to_owned(),
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                .to_owned(),
        )
        .expect("provisioning envelope");
        assert!(!encoded.is_empty());
    }
}
