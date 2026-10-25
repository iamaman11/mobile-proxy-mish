//! One optional 24-hour external proxy credential lease: non-secret Rust Credentials policy.
//!
//! This domain model never changes the existing primary credential. The composition adapter
//! must provide a trusted clock and atomically persist its updated state before authorizing a
//! temporary connection. Neither secrets nor storage/clock effects belong in this pure module.

use crate::proto::{ProtoReader, WIRE_VARINT, write_varint_field};
use std::{error::Error, fmt};

pub const TEMPORARY_CREDENTIAL_TTL_SECONDS: u64 = 24 * 60 * 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TemporaryCredentialStatus {
    Active,
    Expired,
    Revoked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TemporaryCredentialError {
    MissingTrustedClock,
    InvalidActivationTime,
    InvalidGeneration,
    DeadlineOverflow,
    MalformedState,
    NonCanonicalState,
}

impl fmt::Display for TemporaryCredentialError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::MissingTrustedClock => "trusted temporary credential clock unavailable",
            Self::InvalidActivationTime => "invalid temporary credential activation time",
            Self::InvalidGeneration => "invalid temporary credential generation",
            Self::DeadlineOverflow => "temporary credential deadline overflow",
            Self::MalformedState => "temporary credential lease state malformed",
            Self::NonCanonicalState => "temporary credential lease state non-canonical",
        })
    }
}

impl Error for TemporaryCredentialError {}

/// No plaintext secret material: just the one durable temporary grant decision.
/// Generations must be uniquely assigned by the future provisioning adapter.
/// Persist every new state before honoring an affirmative observation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TemporaryCredentialLease {
    generation: u64,
    activated_at_unix_seconds: u64,
    expires_at_unix_seconds: u64,
    last_observed_unix_seconds: u64,
    status: TemporaryCredentialStatus,
}

impl TemporaryCredentialLease {
    pub fn activate(
        generation: u64,
        trusted_unix_seconds: Option<u64>,
    ) -> Result<Self, TemporaryCredentialError> {
        if generation == 0 {
            return Err(TemporaryCredentialError::InvalidGeneration);
        }
        let now = trusted_unix_seconds.ok_or(TemporaryCredentialError::MissingTrustedClock)?;
        if now == 0 {
            return Err(TemporaryCredentialError::InvalidActivationTime);
        }
        let expires_at = now
            .checked_add(TEMPORARY_CREDENTIAL_TTL_SECONDS)
            .ok_or(TemporaryCredentialError::DeadlineOverflow)?;
        Ok(Self {
            generation,
            activated_at_unix_seconds: now,
            expires_at_unix_seconds: expires_at,
            last_observed_unix_seconds: now,
            status: TemporaryCredentialStatus::Active,
        })
    }

    pub const fn generation(self) -> u64 {
        self.generation
    }

    pub const fn activated_at_unix_seconds(self) -> u64 {
        self.activated_at_unix_seconds
    }

    pub const fn expires_at_unix_seconds(self) -> u64 {
        self.expires_at_unix_seconds
    }

    pub const fn last_observed_unix_seconds(self) -> u64 {
        self.last_observed_unix_seconds
    }

    pub const fn status(self) -> TemporaryCredentialStatus {
        self.status
    }

    /// Fail closed on expiry, absent time authority or detected clock rollback.
    /// The caller MUST atomically persist the returned state before admission.
    /// A revoked/expired generation can never be resurrected by the same grant.
    #[must_use]
    pub fn observe(self, trusted_unix_seconds: Option<u64>) -> (Self, bool) {
        if self.status != TemporaryCredentialStatus::Active {
            return (self, false);
        }
        let Some(now) = trusted_unix_seconds else {
            return (self.revoke(), false);
        };
        if now < self.activated_at_unix_seconds || now < self.last_observed_unix_seconds {
            return (self.revoke(), false);
        }
        if now >= self.expires_at_unix_seconds {
            return (
                Self {
                    last_observed_unix_seconds: now,
                    status: TemporaryCredentialStatus::Expired,
                    ..self
                },
                false,
            );
        }
        (
            Self {
                last_observed_unix_seconds: now,
                ..self
            },
            true,
        )
    }

    #[must_use]
    pub const fn revoke(self) -> Self {
        Self {
            status: TemporaryCredentialStatus::Revoked,
            ..self
        }
    }
}

/// Canonical non-secret lease metadata encoding. Credential secrets are never written here.
/// A platform adapter must commit this state atomically with its separately protected secret.
pub fn encode_temporary_lease(lease: TemporaryCredentialLease) -> Vec<u8> {
    let mut output = Vec::with_capacity(48);
    write_varint_field(&mut output, 1, lease.generation);
    write_varint_field(&mut output, 2, lease.activated_at_unix_seconds);
    write_varint_field(&mut output, 3, lease.expires_at_unix_seconds);
    write_varint_field(&mut output, 4, lease.last_observed_unix_seconds);
    let status = match lease.status {
        TemporaryCredentialStatus::Active => 1,
        TemporaryCredentialStatus::Expired => 2,
        TemporaryCredentialStatus::Revoked => 3,
    };
    write_varint_field(&mut output, 5, status);
    output
}

/// Rejects missing/duplicate/unknown or non-minimal fields and impossible lifetime values.
/// A restored Active lease is NOT authorized until the caller performs a fresh trusted-clock
/// observation and durably persists the resulting state.
pub fn decode_temporary_lease(
    input: &[u8],
) -> Result<TemporaryCredentialLease, TemporaryCredentialError> {
    let mut reader = ProtoReader::new(input);
    let mut fields: [Option<u64>; 5] = [None; 5];
    while !reader.exhausted() {
        let tag = reader
            .read_tag()
            .map_err(|_| TemporaryCredentialError::MalformedState)?;
        if !(1..=5).contains(&tag.field_number) || tag.wire_type != WIRE_VARINT {
            return Err(TemporaryCredentialError::MalformedState);
        }
        let slot = &mut fields[(tag.field_number - 1) as usize];
        if slot.is_some() {
            return Err(TemporaryCredentialError::MalformedState);
        }
        *slot = Some(
            reader
                .read_varint()
                .map_err(|_| TemporaryCredentialError::MalformedState)?,
        );
    }
    let [Some(generation), Some(start), Some(end), Some(last), Some(status)] = fields else {
        return Err(TemporaryCredentialError::MalformedState);
    };
    if generation == 0 || start == 0
        || start.checked_add(TEMPORARY_CREDENTIAL_TTL_SECONDS) != Some(end)
        || last < start
    {
        return Err(TemporaryCredentialError::MalformedState);
    }
    let status = match status {
        1 if last < end => TemporaryCredentialStatus::Active,
        2 if last >= end => TemporaryCredentialStatus::Expired,
        3 => TemporaryCredentialStatus::Revoked,
        _ => return Err(TemporaryCredentialError::MalformedState),
    };
    let state = TemporaryCredentialLease {
        generation,
        activated_at_unix_seconds: start,
        expires_at_unix_seconds: end,
        last_observed_unix_seconds: last,
        status,
    };
    if encode_temporary_lease(state) != input {
        return Err(TemporaryCredentialError::NonCanonicalState);
    }
    Ok(state)
}

#[cfg(test)]
mod tests {
    use super::*;

    const AT: u64 = 1_800_000_000;

    #[test]
    fn expiration_is_exactly_24_hours_exclusive() {
        let grant = TemporaryCredentialLease::activate(1, Some(AT)).expect("activate");
        assert_eq!(grant.generation(), 1);
        assert_eq!(grant.activated_at_unix_seconds(), AT);
        assert_eq!(grant.expires_at_unix_seconds(), AT + 86_400);
        let (grant, allowed) = grant.observe(Some(AT + 86_399));
        assert!(allowed);
        let (grant, allowed) = grant.observe(Some(AT + 86_400));
        assert!(!allowed);
        assert_eq!(grant.status(), TemporaryCredentialStatus::Expired);
        assert!(!grant.observe(Some(AT + 86_401)).1);
    }

    #[test]
    fn restart_restores_deadline_without_renewal() {
        let grant = TemporaryCredentialLease::activate(5, Some(AT)).expect("activate");
        let (stored, allowed) = grant.observe(Some(AT + 50_000));
        assert!(allowed);
        assert_eq!(stored.last_observed_unix_seconds(), AT + 50_000);
        let (reopened, allowed) = stored.observe(Some(AT + 86_401));
        assert!(!allowed);
        assert_eq!(reopened.status(), TemporaryCredentialStatus::Expired);
    }

    #[test]
    fn revoke_is_idempotent_permanent_and_separate() {
        let grant = TemporaryCredentialLease::activate(9, Some(AT)).expect("activate");
        let revoked = grant.revoke().revoke();
        assert_eq!(revoked.generation(), 9);
        assert_eq!(revoked.status(), TemporaryCredentialStatus::Revoked);
        assert!(!revoked.observe(Some(AT + 1)).1);
    }

    #[test]
    fn missing_time_and_rollback_fail_closed_permanently() {
        let grant = TemporaryCredentialLease::activate(3, Some(AT)).expect("activate");
        let (grant, allowed) = grant.observe(Some(AT + 10));
        assert!(allowed);
        let (grant, allowed) = grant.observe(Some(AT + 9));
        assert!(!allowed);
        assert_eq!(grant.status(), TemporaryCredentialStatus::Revoked);
        assert!(!grant.observe(Some(AT + 11)).1);
        let grant = TemporaryCredentialLease::activate(4, Some(AT)).expect("activate");
        let (grant, allowed) = grant.observe(None);
        assert!(!allowed);
        assert_eq!(grant.status(), TemporaryCredentialStatus::Revoked);
    }

    #[test]
    fn temporary_lifecycle_never_rotates_existing_primary_material() {
        use crate::{DERIVATION_OUTPUT_BYTES, ExternalCredentialState};

        let primary = ExternalCredentialState::initial();
        let stable = primary
            .materialize(
                &[0x33; DERIVATION_OUTPUT_BYTES],
                &[0x55; DERIVATION_OUTPUT_BYTES],
            )
            .expect("materialize original primary");

        let temporary = TemporaryCredentialLease::activate(7, Some(AT)).expect("activate");
        let (temporary, admitted) = temporary.observe(Some(AT + 1));
        assert!(admitted);
        assert_eq!(
            temporary.revoke().status(),
            TemporaryCredentialStatus::Revoked
        );

        assert_eq!(primary, ExternalCredentialState::initial());
        assert_eq!(
            primary
                .materialize(
                    &[0x33; DERIVATION_OUTPUT_BYTES],
                    &[0x55; DERIVATION_OUTPUT_BYTES],
                )
                .expect("materialize unchanged primary"),
            stable,
        );
    }

    #[test]
    fn durable_lease_round_trip_never_resets_activation_or_expiry() {
        let grant = TemporaryCredentialLease::activate(11, Some(AT)).expect("activate");
        let (grant, accepted) = grant.observe(Some(AT + 50_000));
        assert!(accepted);
        let bytes = encode_temporary_lease(grant);
        let restored = decode_temporary_lease(&bytes).expect("canonical decode");
        assert_eq!(restored, grant);
        assert_eq!(restored.expires_at_unix_seconds(), AT + 86_400);

        let (expired, accepted) = restored.observe(Some(AT + 86_400));
        assert!(!accepted);
        let expired_bytes = encode_temporary_lease(expired);
        assert_eq!(decode_temporary_lease(&expired_bytes), Ok(expired));

        let revoked = grant.revoke();
        assert_eq!(
            decode_temporary_lease(&encode_temporary_lease(revoked)),
            Ok(revoked)
        );
    }

    #[test]
    fn corrupted_noncanonical_and_cross_generation_state_fail_closed() {
        let grant = TemporaryCredentialLease::activate(3, Some(AT)).expect("activate");
        let good = encode_temporary_lease(grant);
        assert_eq!(decode_temporary_lease(&good), Ok(grant));

        let mut duplicate = good.clone();
        duplicate.extend_from_slice(&[0x08, 0x03]);
        assert_eq!(
            decode_temporary_lease(&duplicate),
            Err(TemporaryCredentialError::MalformedState)
        );
        let mut unknown = good.clone();
        unknown.extend_from_slice(&[0x30, 0x01]);
        assert_eq!(
            decode_temporary_lease(&unknown),
            Err(TemporaryCredentialError::MalformedState)
        );
        let mut bad_deadline = good.clone();
        let deadline_position = bad_deadline
            .iter()
            .position(|value| *value == 0x18)
            .expect("field 3 tag");
        bad_deadline[deadline_position + 1] ^= 0x01;
        assert_eq!(
            decode_temporary_lease(&bad_deadline),
            Err(TemporaryCredentialError::MalformedState)
        );
        let mut nonminimal = good.clone();
        nonminimal.splice(0..2, [0x08, 0x83, 0x00]);
        assert_eq!(
            decode_temporary_lease(&nonminimal),
            Err(TemporaryCredentialError::NonCanonicalState)
        );
    }

    #[test]
    fn unsafe_activation_is_rejected() {
        assert_eq!(
            TemporaryCredentialLease::activate(0, Some(AT)),
            Err(TemporaryCredentialError::InvalidGeneration)
        );
        assert_eq!(
            TemporaryCredentialLease::activate(1, None),
            Err(TemporaryCredentialError::MissingTrustedClock)
        );
        assert_eq!(
            TemporaryCredentialLease::activate(1, Some(0)),
            Err(TemporaryCredentialError::InvalidActivationTime)
        );
        assert_eq!(
            TemporaryCredentialLease::activate(1, Some(u64::MAX - 10)),
            Err(TemporaryCredentialError::DeadlineOverflow)
        );
    }
}
