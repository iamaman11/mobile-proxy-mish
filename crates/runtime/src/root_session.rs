//! One process-generation persistent Magisk root session.
//!
//! The session is a runtime mechanism, not a policy owner. All command strings are constructed by
//! sealed Rust capabilities (root policy / rotation); no arbitrary shell API crosses FFI.

use std::future::Future;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;
use tokio::time::timeout;

const COMMAND_TIMEOUT: Duration = Duration::from_secs(10);
const PROCESS_STOP_TIMEOUT: Duration = Duration::from_millis(500);
const MAX_OUTPUT_BYTES: usize = 4096;
const MARKER_PREFIX: &str = "__MISH_ROOT_DONE_";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RootCommandKind {
    Observation,
    Mutation,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RootCommand {
    kind: RootCommandKind,
    command: String,
}

impl RootCommand {
    pub(crate) fn observation(command: impl Into<String>) -> Result<Self, RootSessionError> {
        Self::new(RootCommandKind::Observation, command.into())
    }

    pub(crate) fn mutation(command: impl Into<String>) -> Result<Self, RootSessionError> {
        Self::new(RootCommandKind::Mutation, command.into())
    }

    fn new(kind: RootCommandKind, command: String) -> Result<Self, RootSessionError> {
        if command.is_empty()
            || command.contains('\n')
            || command.contains('\r')
            || command.as_bytes().contains(&0)
        {
            return Err(RootSessionError::InvalidCommand);
        }
        Ok(Self { kind, command })
    }

    pub(crate) fn command(&self) -> &str {
        &self.command
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RootCommandResult {
    pub(crate) exit_code: i32,
    pub(crate) stdout: String,
    pub(crate) timed_out: bool,
    pub(crate) output_complete: bool,
    pub(crate) session_generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootSessionError {
    InvalidCommand,
    SpawnUnavailable,
    StateUnavailable,
}

struct RootCommandOutcome {
    result: RootCommandResult,
    transport_healthy: bool,
}

struct RootShellSession {
    generation: u64,
    sequence: u64,
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl RootShellSession {
    async fn start(generation: u64) -> Result<Self, RootSessionError> {
        // Android's shell performs the stderr merge and is replaced by su via exec, so there is
        // still exactly one persistent privilege process rather than one shell per command.
        Self::start_with_process(generation, "sh", &["-c", "exec su 2>&1"]).await
    }

    async fn start_with_process(
        generation: u64,
        program: &str,
        args: &[&str],
    ) -> Result<Self, RootSessionError> {
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|_| RootSessionError::SpawnUnavailable)?;
        let stdin = child
            .stdin
            .take()
            .ok_or(RootSessionError::SpawnUnavailable)?;
        let stdout = child
            .stdout
            .take()
            .ok_or(RootSessionError::SpawnUnavailable)?;
        Ok(Self {
            generation,
            sequence: 0,
            child,
            stdin,
            stdout: BufReader::new(stdout),
        })
    }

    #[cfg(test)]
    async fn start_unprivileged_for_test(generation: u64) -> Result<Self, RootSessionError> {
        Self::start_with_process(generation, "sh", &[]).await
    }

    async fn execute(&mut self, command: &RootCommand) -> RootCommandOutcome {
        self.sequence = self.sequence.saturating_add(1);
        let marker = format!("{MARKER_PREFIX}{}_{}", self.generation, self.sequence);
        let framed = format!(
            "{}\n__mish_root_status=$?; printf '\\n{}:%s\\n' \"$__mish_root_status\"\n",
            command.command(),
            marker,
        );
        if self.stdin.write_all(framed.as_bytes()).await.is_err()
            || self.stdin.flush().await.is_err()
        {
            return self.unavailable_outcome();
        }

        let generation = self.generation;
        let read = timeout(COMMAND_TIMEOUT, async {
            let mut captured = String::new();
            let mut captured_bytes = 0usize;
            let mut output_complete = true;
            loop {
                let mut line = String::new();
                let count = match self.stdout.read_line(&mut line).await {
                    Ok(count) => count,
                    Err(_) => {
                        return RootCommandOutcome {
                            result: RootCommandResult {
                                exit_code: -1,
                                stdout: String::new(),
                                timed_out: false,
                                output_complete: false,
                                session_generation: generation,
                            },
                            transport_healthy: false,
                        };
                    }
                };
                if count == 0 {
                    let exit_code = self
                        .child
                        .try_wait()
                        .ok()
                        .flatten()
                        .and_then(|status| status.code());
                    let authoritative_denial = exit_code.filter(|code| *code != 0);
                    return RootCommandOutcome {
                        result: if let Some(exit_code) = authoritative_denial {
                            RootCommandResult {
                                exit_code,
                                stdout: captured,
                                timed_out: false,
                                output_complete,
                                session_generation: generation,
                            }
                        } else {
                            RootCommandResult {
                                exit_code: -1,
                                stdout: String::new(),
                                timed_out: false,
                                output_complete: false,
                                session_generation: generation,
                            }
                        },
                        transport_healthy: false,
                    };
                }

                let trimmed = line.trim_end_matches(['\r', '\n']);
                if let Some(raw_status) = trimmed.strip_prefix(&format!("{marker}:")) {
                    let exit_code = match raw_status.parse::<i32>() {
                        Ok(exit_code) => exit_code,
                        Err(_) => {
                            return RootCommandOutcome {
                                result: RootCommandResult {
                                    exit_code: -1,
                                    stdout: String::new(),
                                    timed_out: false,
                                    output_complete: false,
                                    session_generation: generation,
                                },
                                transport_healthy: false,
                            };
                        }
                    };
                    return RootCommandOutcome {
                        result: RootCommandResult {
                            exit_code,
                            stdout: captured,
                            timed_out: false,
                            output_complete,
                            session_generation: generation,
                        },
                        transport_healthy: true,
                    };
                }

                let bytes = line.len();
                if captured_bytes.saturating_add(bytes) <= MAX_OUTPUT_BYTES {
                    captured.push_str(&line);
                    captured_bytes += bytes;
                } else {
                    output_complete = false;
                }
            }
        })
        .await;

        match read {
            Ok(outcome) => outcome,
            Err(_) => {
                self.destroy().await;
                RootCommandOutcome {
                    result: RootCommandResult {
                        exit_code: -1,
                        stdout: String::new(),
                        timed_out: true,
                        output_complete: false,
                        session_generation: generation,
                    },
                    transport_healthy: false,
                }
            }
        }
    }

    async fn destroy(&mut self) {
        let _ = self.stdin.shutdown().await;
        if self.child.id().is_some() {
            let _ = self.child.start_kill();
            let _ = timeout(PROCESS_STOP_TIMEOUT, self.child.wait()).await;
        }
    }

    fn unavailable_outcome(&self) -> RootCommandOutcome {
        RootCommandOutcome {
            result: RootCommandResult {
                exit_code: -1,
                stdout: String::new(),
                timed_out: false,
                output_complete: false,
                session_generation: self.generation,
            },
            transport_healthy: false,
        }
    }
}

struct RootSessionState {
    session: Option<RootShellSession>,
    next_generation: u64,
}

/// Serialized owner of the one live root process.
///
/// A transport failure destroys the current shell but never replays the command. The next caller
/// may establish a fresh session generation; policy code must re-observe before retrying mutation.
pub(crate) struct RootSessionManager {
    state: Mutex<RootSessionState>,
}

impl RootSessionManager {
    pub(crate) fn new() -> Self {
        Self {
            state: Mutex::new(RootSessionState {
                session: None,
                next_generation: 1,
            }),
        }
    }

    pub(crate) async fn execute(
        &self,
        command: RootCommand,
    ) -> Result<RootCommandResult, RootSessionError> {
        self.execute_with_starter(command, RootShellSession::start)
            .await
    }

    async fn execute_with_starter<F, Fut>(
        &self,
        command: RootCommand,
        starter: F,
    ) -> Result<RootCommandResult, RootSessionError>
    where
        F: FnOnce(u64) -> Fut,
        Fut: Future<Output = Result<RootShellSession, RootSessionError>>,
    {
        let mut state = self.state.lock().await;
        if state.session.is_none() {
            let generation = state.next_generation;
            state.next_generation = state
                .next_generation
                .checked_add(1)
                .ok_or(RootSessionError::StateUnavailable)?;
            state.session = Some(starter(generation).await?);
        }

        let outcome = match state.session.as_mut() {
            Some(session) => session.execute(&command).await,
            None => return Err(RootSessionError::StateUnavailable),
        };
        if !outcome.transport_healthy
            && let Some(mut session) = state.session.take()
        {
            session.destroy().await;
        }
        Ok(outcome.result)
    }

    pub(crate) async fn session_generation(&self) -> Option<u64> {
        self.state
            .lock()
            .await
            .session
            .as_ref()
            .map(|session| session.generation)
    }

    pub(crate) async fn shutdown(&self) {
        let mut state = self.state.lock().await;
        if let Some(mut session) = state.session.take() {
            session.destroy().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_command_boundary_rejects_multiline_or_empty_input() {
        assert_eq!(
            RootCommand::observation("").unwrap_err(),
            RootSessionError::InvalidCommand
        );
        assert_eq!(
            RootCommand::mutation("echo ok\nrm -rf /").unwrap_err(),
            RootSessionError::InvalidCommand
        );
        assert!(RootCommand::observation("ip -4 rule show").is_ok());
    }

    #[test]
    fn observation_and_mutation_remain_distinct_types() {
        assert_eq!(
            RootCommand::observation("id -u").expect("observation").kind,
            RootCommandKind::Observation
        );
        assert_eq!(
            RootCommand::mutation("true").expect("mutation").kind,
            RootCommandKind::Mutation
        );
    }

    #[test]
    fn nonzero_pre_marker_exit_remains_authoritative_denial_data() {
        let result = RootCommandResult {
            exit_code: 1,
            stdout: "permission denied\n".to_owned(),
            timed_out: false,
            output_complete: true,
            session_generation: 1,
        };
        assert!(result.timed_out || !result.output_complete || result.exit_code != 0);
        assert!(result.exit_code > 0);
    }

    #[tokio::test]
    async fn uncertain_mutation_is_not_replayed_after_shell_death() {
        use std::time::{SystemTime, UNIX_EPOCH};

        let path = format!(
            "/tmp/mish-root-session-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system clock")
                .as_nanos(),
        );
        let manager = RootSessionManager::new();

        let uncertain = RootCommand::mutation(format!(
            "printf x >> {path}; kill -9 $"
        ))
        .expect("valid mutation");
        let first = manager
            .execute_with_starter(uncertain, RootShellSession::start_unprivileged_for_test)
            .await
            .expect("transport failure remains command outcome");

        assert_eq!(first.session_generation, 1);
        assert_eq!(first.exit_code, -1);
        assert!(!first.output_complete);
        assert!(!first.timed_out);
        assert_eq!(manager.session_generation().await, None);

        let observe = RootCommand::observation(format!("cat {path}")).expect("valid observation");
        let second = manager
            .execute_with_starter(observe, RootShellSession::start_unprivileged_for_test)
            .await
            .expect("replacement session");
        assert_eq!(second.session_generation, 2);
        assert_eq!(second.exit_code, 0);
        assert!(second.output_complete);
        assert_eq!(second.stdout, "x\n");
        assert_eq!(manager.session_generation().await, Some(2));

        let observe_again =
            RootCommand::observation(format!("cat {path}")).expect("valid observation");
        let third = manager
            .execute_with_starter(observe_again, RootShellSession::start_unprivileged_for_test)
            .await
            .expect("same healthy replacement session");
        assert_eq!(third.session_generation, 2);
        assert_eq!(third.stdout, "x\n");

        let _ = std::fs::remove_file(path);
        manager.shutdown().await;
    }

    #[test]
    fn authoritative_success_requires_complete_zero_exit() {
        let success = RootCommandResult {
            exit_code: 0,
            stdout: String::new(),
            timed_out: false,
            output_complete: true,
            session_generation: 1,
        };
        assert!(!success.timed_out && success.output_complete && success.exit_code == 0);

        let denied = RootCommandResult {
            exit_code: 1,
            stdout: String::new(),
            timed_out: false,
            output_complete: true,
            session_generation: 1,
        };
        assert!(!(!denied.timed_out && denied.output_complete && denied.exit_code == 0));
    }
}
