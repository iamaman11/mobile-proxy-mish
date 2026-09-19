use crate::proto::{ProtoReader, WIRE_VARINT, write_varint_field};
use crate::{ExternalCredentialError, ExternalCredentialState, ExternalCredentialStatus};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExternalCredentialPersistenceAction {
    UseCurrent,
    PersistCanonical,
    CreateRootAndPersistCanonical,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalCredentialPersistenceResolution {
    state: ExternalCredentialState,
    canonical_state: Vec<u8>,
    action: ExternalCredentialPersistenceAction,
}

impl ExternalCredentialPersistenceResolution {
    pub const fn state(&self) -> ExternalCredentialState {
        self.state
    }

    pub fn canonical_state(&self) -> &[u8] {
        &self.canonical_state
    }

    pub const fn action(&self) -> ExternalCredentialPersistenceAction {
        self.action
    }
}

pub fn encode_state(state: ExternalCredentialState) -> Vec<u8> {
    let mut encoded = Vec::with_capacity(12);
    write_varint_field(&mut encoded, 1, state.version());
    if state.status() == ExternalCredentialStatus::Revoked {
        write_varint_field(&mut encoded, 2, 1);
    }
    encoded
}

pub fn decode_state(encoded: &[u8]) -> Result<ExternalCredentialState, ExternalCredentialError> {
    let mut reader = ProtoReader::new(encoded);
    let mut version = None;
    let mut revoked = false;
    let mut revoked_seen = false;

    while !reader.exhausted() {
        let tag = reader
            .read_tag()
            .map_err(|_| ExternalCredentialError::MalformedState)?;
        match tag.field_number {
            1 => {
                if tag.wire_type != WIRE_VARINT || version.is_some() {
                    return Err(ExternalCredentialError::MalformedState);
                }
                version = Some(
                    reader
                        .read_varint()
                        .map_err(|_| ExternalCredentialError::MalformedState)?,
                );
            }
            2 => {
                if tag.wire_type != WIRE_VARINT || revoked_seen {
                    return Err(ExternalCredentialError::MalformedState);
                }
                revoked_seen = true;
                revoked = match reader
                    .read_varint()
                    .map_err(|_| ExternalCredentialError::MalformedState)?
                {
                    0 => false,
                    1 => true,
                    _ => return Err(ExternalCredentialError::MalformedState),
                };
            }
            _ => reader
                .skip(tag.wire_type)
                .map_err(|_| ExternalCredentialError::MalformedState)?,
        }
    }

    let version = version.ok_or(ExternalCredentialError::MalformedState)?;
    ExternalCredentialState::new(
        version,
        if revoked {
            ExternalCredentialStatus::Revoked
        } else {
            ExternalCredentialStatus::Active
        },
    )
}

pub fn resolve_persistence(
    canonical_state: Option<&[u8]>,
    legacy_version: Option<&str>,
    legacy_revoked: Option<bool>,
    root_exists: bool,
) -> Result<ExternalCredentialPersistenceResolution, ExternalCredentialError> {
    if let Some(encoded) = canonical_state {
        if legacy_version.is_some() || legacy_revoked.is_some() {
            return Err(ExternalCredentialError::MixedPersistenceSchemas);
        }
        if !root_exists {
            return Err(ExternalCredentialError::MissingRootForState);
        }
        let state = decode_state(encoded)?;
        let canonical = encode_state(state);
        if canonical != encoded {
            return Err(ExternalCredentialError::NonCanonicalState);
        }
        return Ok(ExternalCredentialPersistenceResolution {
            state,
            canonical_state: canonical,
            action: ExternalCredentialPersistenceAction::UseCurrent,
        });
    }

    if legacy_version.is_some() != legacy_revoked.is_some() {
        return Err(ExternalCredentialError::IncompleteLegacyState);
    }

    if let (Some(raw_version), Some(revoked)) = (legacy_version, legacy_revoked) {
        if !root_exists {
            return Err(ExternalCredentialError::MissingRootForState);
        }
        let version = raw_version
            .parse::<u64>()
            .map_err(|_| ExternalCredentialError::InvalidLegacyVersion)?;
        let state = ExternalCredentialState::new(
            version,
            if revoked {
                ExternalCredentialStatus::Revoked
            } else {
                ExternalCredentialStatus::Active
            },
        )
        .map_err(|_| ExternalCredentialError::InvalidLegacyVersion)?;
        return Ok(ExternalCredentialPersistenceResolution {
            state,
            canonical_state: encode_state(state),
            action: ExternalCredentialPersistenceAction::PersistCanonical,
        });
    }

    if root_exists {
        return Err(ExternalCredentialError::RootWithoutState);
    }

    let state = ExternalCredentialState::initial();
    Ok(ExternalCredentialPersistenceResolution {
        state,
        canonical_state: encode_state(state),
        action: ExternalCredentialPersistenceAction::CreateRootAndPersistCanonical,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_codec_is_canonical_and_strict() {
        let active = ExternalCredentialState::new(7, ExternalCredentialStatus::Active)
            .expect("active state");
        let revoked = ExternalCredentialState::new(7, ExternalCredentialStatus::Revoked)
            .expect("revoked state");

        assert_eq!(encode_state(active), vec![0x08, 0x07]);
        assert_eq!(encode_state(revoked), vec![0x08, 0x07, 0x10, 0x01]);
        assert_eq!(decode_state(&encode_state(revoked)), Ok(revoked));
        assert_eq!(
            decode_state(&[0x10, 0x01]),
            Err(ExternalCredentialError::MalformedState)
        );
        assert_eq!(
            decode_state(&[0x08, 0x07, 0x10, 0x02]),
            Err(ExternalCredentialError::MalformedState)
        );
    }

    #[test]
    fn persistence_initializes_migrates_and_reads_without_advancing_version() {
        let initial = resolve_persistence(None, None, None, false).expect("initialize plan");
        assert_eq!(
            initial.action(),
            ExternalCredentialPersistenceAction::CreateRootAndPersistCanonical
        );
        assert_eq!(initial.state().version(), 1);

        let migrated =
            resolve_persistence(None, Some("7"), Some(false), true).expect("legacy migration");
        assert_eq!(
            migrated.action(),
            ExternalCredentialPersistenceAction::PersistCanonical
        );
        assert_eq!(migrated.state().version(), 7);
        assert_eq!(migrated.canonical_state(), &[0x08, 0x07]);

        let current = resolve_persistence(Some(migrated.canonical_state()), None, None, true)
            .expect("current read");
        assert_eq!(
            current.action(),
            ExternalCredentialPersistenceAction::UseCurrent
        );
        assert_eq!(current.state().version(), 7);
        assert_eq!(current.canonical_state(), migrated.canonical_state());
    }

    #[test]
    fn persistence_rejects_mixed_or_incoherent_storage() {
        let canonical = encode_state(ExternalCredentialState::initial());
        assert_eq!(
            resolve_persistence(Some(&canonical), Some("1"), Some(false), true),
            Err(ExternalCredentialError::MixedPersistenceSchemas)
        );
        assert_eq!(
            resolve_persistence(None, Some("1"), None, true),
            Err(ExternalCredentialError::IncompleteLegacyState)
        );
        assert_eq!(
            resolve_persistence(Some(&canonical), None, None, false),
            Err(ExternalCredentialError::MissingRootForState)
        );
        assert_eq!(
            resolve_persistence(None, None, None, true),
            Err(ExternalCredentialError::RootWithoutState)
        );
        assert_eq!(
            resolve_persistence(Some(&[0x08, 0x01, 0x10, 0x00]), None, None, true),
            Err(ExternalCredentialError::NonCanonicalState)
        );
    }
}
