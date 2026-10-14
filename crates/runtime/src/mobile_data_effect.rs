//! Typed mobile-data effects over the one persistent PRODUCT root session.
//!
//! Command construction is sealed here. Callers can only observe the authoritative global
//! mobile-data setting or request one enable/disable mutation; no arbitrary shell string crosses
//! this capability and RootSessionManager never replays an uncertain mutation.
//!
//! The one bit of state in this effect is not a second Rotation state machine. It records only
//! whether this exact effect instance has crossed the point where its own disable mutation may
//! have changed Android state. Compensation is therefore physically impossible before ownership
//! exists, and enable success is released only after an authoritative readback proves `1`.

use crate::root_session::{RootCommand, RootSessionError, RootSessionManager};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MobileDataState {
    Enabled,
    Disabled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MobileDataEffectError {
    SessionUnavailable,
    ObservationIncomplete,
    ObservationRejected,
    InvalidObservation,
    MutationRejected,
    MutationUncertain,
    MutationNotOwned,
}

pub(crate) struct MobileDataEffect {
    session: Arc<RootSessionManager>,
    compensation_owned: AtomicBool,
}

impl MobileDataEffect {
    pub(crate) fn new(session: Arc<RootSessionManager>) -> Arc<Self> {
        Arc::new(Self {
            session,
            compensation_owned: AtomicBool::new(false),
        })
    }

    pub(crate) async fn observe(&self) -> Result<MobileDataState, MobileDataEffectError> {
        let command = RootCommand::observation("settings get global mobile_data")
            .map_err(map_session_error)?;
        let result = self
            .session
            .execute(command)
            .await
            .map_err(map_session_error)?;
        if result.timed_out || !result.output_complete {
            return Err(MobileDataEffectError::ObservationIncomplete);
        }
        if result.exit_code != 0 {
            return Err(MobileDataEffectError::ObservationRejected);
        }
        parse_mobile_data_state(&result.stdout).ok_or(MobileDataEffectError::InvalidObservation)
    }

    pub(crate) async fn set(&self, state: MobileDataState) -> Result<(), MobileDataEffectError> {
        match state {
            MobileDataState::Disabled => self.disable().await,
            MobileDataState::Enabled => self.enable_and_verify().await,
        }
    }

    async fn disable(&self) -> Result<(), MobileDataEffectError> {
        // Rotation is single-operation, so a second outstanding compensation owner is always an
        // inconsistent/uncertain state. Never issue another disable in that condition.
        if self
            .compensation_owned
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(MobileDataEffectError::MutationUncertain);
        }

        // Ownership is recorded immediately before the mutation is handed to the root transport.
        // If the caller deadline races before this point, a later restore cannot mutate Android.
        let command = RootCommand::mutation("cmd phone data disable").map_err(|error| {
            self.compensation_owned.store(false, Ordering::Release);
            map_session_error(error)
        })?;
        let result = match self.session.execute(command).await {
            Ok(result) => result,
            Err(_) => return Err(MobileDataEffectError::MutationUncertain),
        };
        if result.timed_out || !result.output_complete {
            return Err(MobileDataEffectError::MutationUncertain);
        }
        if result.exit_code != 0 {
            // A complete non-zero result is a rejected mutation, not an uncertain mutation. This
            // effect therefore never acquired a state that needs compensating.
            self.compensation_owned.store(false, Ordering::Release);
            return Err(MobileDataEffectError::MutationRejected);
        }
        Ok(())
    }

    async fn enable_and_verify(&self) -> Result<(), MobileDataEffectError> {
        // Do not let a generic recovery path turn a pre-existing user-disabled state on. Only this
        // effect's own prior disable attempt grants permission for one enable mutation.
        if !self.compensation_owned.load(Ordering::Acquire) {
            return Err(MobileDataEffectError::MutationNotOwned);
        }

        let command = RootCommand::mutation("cmd phone data enable").map_err(map_session_error)?;
        let mutation = self.session.execute(command).await;

        let mutation_outcome = match mutation {
            Ok(result) if result.timed_out || !result.output_complete => {
                MobileDataEffectError::MutationUncertain
            }
            Ok(result) if result.exit_code != 0 => MobileDataEffectError::MutationRejected,
            Ok(_) => MobileDataEffectError::MutationUncertain,
            Err(_) => MobileDataEffectError::MutationUncertain,
        };

        // Command completion alone never proves recovery. A fresh read-only observation is allowed
        // after a certain or uncertain root mutation and does not replay the mutation.
        match self.observe().await {
            Ok(MobileDataState::Enabled) => {
                self.compensation_owned.store(false, Ordering::Release);
                Ok(())
            }
            Ok(MobileDataState::Disabled) => Err(mutation_outcome),
            Err(_) => Err(MobileDataEffectError::MutationUncertain),
        }
    }
}

fn map_session_error(_: RootSessionError) -> MobileDataEffectError {
    MobileDataEffectError::SessionUnavailable
}

fn parse_mobile_data_state(raw: &str) -> Option<MobileDataState> {
    match raw.trim() {
        "1" => Some(MobileDataState::Enabled),
        "0" => Some(MobileDataState::Disabled),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observation_parser_accepts_only_authoritative_android_setting_values() {
        assert_eq!(parse_mobile_data_state("1\n"), Some(MobileDataState::Enabled));
        assert_eq!(parse_mobile_data_state("0\n"), Some(MobileDataState::Disabled));
        assert_eq!(parse_mobile_data_state("true"), None);
        assert_eq!(parse_mobile_data_state("enabled"), None);
        assert_eq!(parse_mobile_data_state("null"), None);
    }

    #[test]
    fn typed_effect_owns_exact_candidate_a_commands() {
        assert_eq!(
            RootCommand::observation("settings get global mobile_data")
                .expect("observe")
                .command(),
            "settings get global mobile_data"
        );
        assert_eq!(
            RootCommand::mutation("cmd phone data disable")
                .expect("disable")
                .command(),
            "cmd phone data disable"
        );
        assert_eq!(
            RootCommand::mutation("cmd phone data enable")
                .expect("enable")
                .command(),
            "cmd phone data enable"
        );
    }
}
