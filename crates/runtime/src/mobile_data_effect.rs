//! Typed mobile-data effects over the one persistent PRODUCT root session.
//!
//! Command construction is sealed here. Callers can only observe the authoritative global
//! mobile-data setting or request one enable/disable mutation; no arbitrary shell string crosses
//! this capability and RootSessionManager never replays an uncertain mutation.

use crate::root_session::{RootCommand, RootSessionError, RootSessionManager};
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
}

pub(crate) struct MobileDataEffect {
    session: Arc<RootSessionManager>,
}

impl MobileDataEffect {
    pub(crate) fn new(session: Arc<RootSessionManager>) -> Arc<Self> {
        Arc::new(Self { session })
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
        let command = match state {
            MobileDataState::Enabled => RootCommand::mutation("cmd phone data enable"),
            MobileDataState::Disabled => RootCommand::mutation("cmd phone data disable"),
        }
        .map_err(map_session_error)?;
        let result = self
            .session
            .execute(command)
            .await
            .map_err(map_session_error)?;
        if result.timed_out || !result.output_complete {
            return Err(MobileDataEffectError::MutationUncertain);
        }
        if result.exit_code != 0 {
            return Err(MobileDataEffectError::MutationRejected);
        }
        Ok(())
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
