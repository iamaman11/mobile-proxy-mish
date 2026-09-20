//! Typed airplane-mode effects over the one persistent PRODUCT root session.
//!
//! Command construction is sealed here. Callers can only observe or request ON/OFF; no arbitrary
//! shell string crosses this capability.

use crate::root_session::{RootCommand, RootSessionError, RootSessionManager};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AirplaneModeState {
    Enabled,
    Disabled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AirplaneEffectError {
    SessionUnavailable,
    ObservationIncomplete,
    ObservationRejected,
    InvalidObservation,
    MutationRejected,
    MutationUncertain,
}

pub(crate) struct AirplaneModeEffect {
    session: Arc<RootSessionManager>,
}

impl AirplaneModeEffect {
    pub(crate) fn new(session: Arc<RootSessionManager>) -> Arc<Self> {
        Arc::new(Self { session })
    }

    pub(crate) async fn observe(&self) -> Result<AirplaneModeState, AirplaneEffectError> {
        let command = RootCommand::observation("cmd connectivity airplane-mode")
            .map_err(map_session_error)?;
        let result = self
            .session
            .execute(command)
            .await
            .map_err(map_session_error)?;
        if result.timed_out || !result.output_complete {
            return Err(AirplaneEffectError::ObservationIncomplete);
        }
        if result.exit_code != 0 {
            return Err(AirplaneEffectError::ObservationRejected);
        }
        parse_airplane_state(&result.stdout).ok_or(AirplaneEffectError::InvalidObservation)
    }

    pub(crate) async fn set(&self, state: AirplaneModeState) -> Result<(), AirplaneEffectError> {
        let command = match state {
            AirplaneModeState::Enabled => {
                RootCommand::mutation("cmd connectivity airplane-mode enable")
            }
            AirplaneModeState::Disabled => {
                RootCommand::mutation("cmd connectivity airplane-mode disable")
            }
        }
        .map_err(map_session_error)?;
        let result = self
            .session
            .execute(command)
            .await
            .map_err(map_session_error)?;
        if result.timed_out || !result.output_complete {
            return Err(AirplaneEffectError::MutationUncertain);
        }
        if result.exit_code != 0 {
            return Err(AirplaneEffectError::MutationRejected);
        }
        Ok(())
    }
}

fn map_session_error(_: RootSessionError) -> AirplaneEffectError {
    AirplaneEffectError::SessionUnavailable
}

fn parse_airplane_state(raw: &str) -> Option<AirplaneModeState> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "enabled" | "true" | "1" | "airplane mode is enabled" => Some(AirplaneModeState::Enabled),
        "disabled" | "false" | "0" | "airplane mode is disabled" => {
            Some(AirplaneModeState::Disabled)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observation_parser_is_strict_but_accepts_android_boolean_variants() {
        for value in ["enabled", "true", "1", "Airplane mode is enabled\n"] {
            assert_eq!(
                parse_airplane_state(value),
                Some(AirplaneModeState::Enabled)
            );
        }
        for value in ["disabled", "false", "0", "Airplane mode is disabled\n"] {
            assert_eq!(
                parse_airplane_state(value),
                Some(AirplaneModeState::Disabled)
            );
        }
        assert_eq!(parse_airplane_state("unknown"), None);
        assert_eq!(parse_airplane_state("enabled extra"), None);
    }

    #[test]
    fn typed_effect_owns_exact_command_strings() {
        assert_eq!(
            RootCommand::observation("cmd connectivity airplane-mode")
                .expect("observe")
                .command(),
            "cmd connectivity airplane-mode"
        );
        assert_eq!(
            RootCommand::mutation("cmd connectivity airplane-mode enable")
                .expect("enable")
                .command(),
            "cmd connectivity airplane-mode enable"
        );
        assert_eq!(
            RootCommand::mutation("cmd connectivity airplane-mode disable")
                .expect("disable")
                .command(),
            "cmd connectivity airplane-mode disable"
        );
    }
}
