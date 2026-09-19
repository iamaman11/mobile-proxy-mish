//! Typed root-policy effect execution over the one native root session.
//!
//! Read-only observations may be repeated once after a non-authoritative transport result.
//! Mutations are never replayed here: an uncertain mutation must be reconciled by fresh
//! observation in the policy transaction.

use crate::root_session::{RootCommand, RootCommandResult, RootSessionError, RootSessionManager};
use std::collections::HashSet;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RootPolicyEffectFailure {
    ObservationUnavailable,
    ObservationIncomplete,
    MutationRejected,
    MutationUncertain,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct RootPolicyCommandWindowDiagnostic {
    pub commands: u64,
    pub observation_commands: u64,
    pub mutation_commands: u64,
    pub duplicate_observations: u64,
    pub incomplete_or_timed_out_commands: u64,
    pub mutation_failures: u64,
}

#[derive(Default)]
pub(crate) struct RootPolicyCommandWindow {
    diagnostic: RootPolicyCommandWindowDiagnostic,
    seen_observations: HashSet<String>,
}

impl RootPolicyCommandWindow {
    pub(crate) const fn diagnostic(&self) -> RootPolicyCommandWindowDiagnostic {
        self.diagnostic
    }

    fn record_observation(&mut self, command: &str, result: &RootCommandResult) {
        self.diagnostic.commands = self.diagnostic.commands.saturating_add(1);
        self.diagnostic.observation_commands =
            self.diagnostic.observation_commands.saturating_add(1);
        if !self.seen_observations.insert(command.to_owned()) {
            self.diagnostic.duplicate_observations =
                self.diagnostic.duplicate_observations.saturating_add(1);
        }
        if result.timed_out || !result.output_complete {
            self.diagnostic.incomplete_or_timed_out_commands = self
                .diagnostic
                .incomplete_or_timed_out_commands
                .saturating_add(1);
        }
    }

    fn record_mutation(&mut self, result: &RootCommandResult) {
        self.diagnostic.commands = self.diagnostic.commands.saturating_add(1);
        self.diagnostic.mutation_commands = self.diagnostic.mutation_commands.saturating_add(1);
        if result.timed_out || !result.output_complete {
            self.diagnostic.incomplete_or_timed_out_commands = self
                .diagnostic
                .incomplete_or_timed_out_commands
                .saturating_add(1);
        }
        if result.timed_out || !result.output_complete || result.exit_code != 0 {
            self.diagnostic.mutation_failures = self.diagnostic.mutation_failures.saturating_add(1);
        }
    }
}

pub(crate) trait RootPolicyIo: Send + Sync {
    fn session_generation<'a>(&'a self) -> Pin<Box<dyn Future<Output = Option<u64>> + Send + 'a>>;

    fn raw_observation<'a>(
        &'a self,
        command: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<RootCommandResult, RootSessionError>> + Send + 'a>>;

    fn observe<'a>(
        &'a self,
        command: &'a str,
        window: &'a mut RootPolicyCommandWindow,
    ) -> Pin<Box<dyn Future<Output = Result<RootCommandResult, RootPolicyEffectFailure>> + Send + 'a>>;

    fn lines<'a>(
        &'a self,
        command: &'a str,
        window: &'a mut RootPolicyCommandWindow,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<String>, RootPolicyEffectFailure>> + Send + 'a>>;

    fn mutate<'a>(
        &'a self,
        command: &'a str,
        window: &'a mut RootPolicyCommandWindow,
    ) -> Pin<Box<dyn Future<Output = Result<(), RootPolicyEffectFailure>> + Send + 'a>>;
}
pub(crate) struct RootPolicyEffectExecutor {
    session: Arc<RootSessionManager>,
}

impl RootPolicyEffectExecutor {
    pub(crate) fn new(session: Arc<RootSessionManager>) -> Self {
        Self { session }
    }

    pub(crate) async fn session_generation(&self) -> Option<u64> {
        self.session.session_generation().await
    }

    pub(crate) async fn raw_observation(
        &self,
        command: &str,
    ) -> Result<RootCommandResult, RootSessionError> {
        let command = RootCommand::observation(command.to_owned())?;
        self.session.execute(command).await
    }

    pub(crate) async fn observe(
        &self,
        command: &str,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<RootCommandResult, RootPolicyEffectFailure> {
        let first = RootCommand::observation(command.to_owned())
            .map_err(|_| RootPolicyEffectFailure::ObservationUnavailable)?;
        let mut result = self
            .session
            .execute(first)
            .await
            .map_err(map_observation_transport_failure)?;
        window.record_observation(command, &result);

        if result.timed_out || !result.output_complete {
            let fresh = RootCommand::observation(command.to_owned())
                .map_err(|_| RootPolicyEffectFailure::ObservationUnavailable)?;
            result = self
                .session
                .execute(fresh)
                .await
                .map_err(map_observation_transport_failure)?;
            window.record_observation(command, &result);
        }

        if result.timed_out || !result.output_complete {
            Err(RootPolicyEffectFailure::ObservationIncomplete)
        } else {
            Ok(result)
        }
    }

    pub(crate) async fn lines(
        &self,
        command: &str,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<Vec<String>, RootPolicyEffectFailure> {
        let result = self.observe(command, window).await?;
        if result.exit_code != 0 {
            return Err(RootPolicyEffectFailure::ObservationUnavailable);
        }
        Ok(result
            .stdout
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
            .collect())
    }

    pub(crate) async fn mutate(
        &self,
        command: &str,
        window: &mut RootPolicyCommandWindow,
    ) -> Result<(), RootPolicyEffectFailure> {
        let mutation = RootCommand::mutation(command.to_owned())
            .map_err(|_| RootPolicyEffectFailure::MutationRejected)?;
        let result = match self.session.execute(mutation).await {
            Ok(result) => result,
            Err(_) => return Err(RootPolicyEffectFailure::MutationUncertain),
        };
        window.record_mutation(&result);

        if result.timed_out || !result.output_complete {
            Err(RootPolicyEffectFailure::MutationUncertain)
        } else if result.exit_code != 0 {
            Err(RootPolicyEffectFailure::MutationRejected)
        } else {
            Ok(())
        }
    }

}

impl RootPolicyIo for RootPolicyEffectExecutor {
    fn session_generation<'a>(&'a self) -> Pin<Box<dyn Future<Output = Option<u64>> + Send + 'a>> {
        Box::pin(async move { RootPolicyEffectExecutor::session_generation(self).await })
    }

    fn raw_observation<'a>(
        &'a self,
        command: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<RootCommandResult, RootSessionError>> + Send + 'a>>
    {
        Box::pin(async move { RootPolicyEffectExecutor::raw_observation(self, command).await })
    }

    fn observe<'a>(
        &'a self,
        command: &'a str,
        window: &'a mut RootPolicyCommandWindow,
    ) -> Pin<Box<dyn Future<Output = Result<RootCommandResult, RootPolicyEffectFailure>> + Send + 'a>>
    {
        Box::pin(async move { RootPolicyEffectExecutor::observe(self, command, window).await })
    }

    fn lines<'a>(
        &'a self,
        command: &'a str,
        window: &'a mut RootPolicyCommandWindow,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<String>, RootPolicyEffectFailure>> + Send + 'a>>
    {
        Box::pin(async move { RootPolicyEffectExecutor::lines(self, command, window).await })
    }

    fn mutate<'a>(
        &'a self,
        command: &'a str,
        window: &'a mut RootPolicyCommandWindow,
    ) -> Pin<Box<dyn Future<Output = Result<(), RootPolicyEffectFailure>> + Send + 'a>> {
        Box::pin(async move { RootPolicyEffectExecutor::mutate(self, command, window).await })
    }
}
fn map_observation_transport_failure(_: RootSessionError) -> RootPolicyEffectFailure {
    RootPolicyEffectFailure::ObservationUnavailable
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failure_vocabulary_keeps_read_and_mutation_uncertainty_distinct() {
        assert_ne!(
            RootPolicyEffectFailure::ObservationUnavailable,
            RootPolicyEffectFailure::MutationUncertain
        );
        assert_ne!(
            RootPolicyEffectFailure::MutationRejected,
            RootPolicyEffectFailure::MutationUncertain
        );
    }
}
