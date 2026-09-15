//! Vendor-neutral owned proxy process reconciliation.
//!
//! Platform adapters only observe bounded process argv snapshots and execute an already-authorized
//! termination target. Ownership classification lives here so shell/Kotlin effects cannot become a
//! second process-identity owner.

const SING_BOX_LIBRARY: &str = "libsingbox.so";
const LEGACY_CONFIG_FILE: &str = "sing-box.json";
const GENERATION_ID_LENGTH: usize = 24;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeProcessObservation {
    pub pid: u64,
    pub argv: Vec<String>,
    pub cmdline_digest: String,
    pub truncated: bool,
    pub unsafe_argv: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeProcessIdentity {
    pub pid: u64,
    pub cmdline_digest: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeProcessTerminationTarget {
    pub pid: u64,
    pub cmdline_digest: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeProcessCleanupDecision {
    Clean,
    TerminateOwned,
    FailClosed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeProcessCleanupPlan {
    pub decision: RuntimeProcessCleanupDecision,
    pub terminate: Vec<RuntimeProcessTerminationTarget>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeCurrentProcessDecision {
    Exact,
    Absent,
    Conflict,
    FailClosed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeCurrentProcessResolution {
    pub decision: RuntimeCurrentProcessDecision,
    pub current: Option<RuntimeProcessIdentity>,
}

/// Classify one bounded process snapshot against the only accepted PRODUCT launch shape.
///
/// Prefix/suffix wrapper argv are tolerated because old process generations may have been started
/// through a launcher utility. The ownership authority is the contiguous exact sequence:
///
/// `*/libsingbox.so`, `run`, `-c`, `<app runtime>/sing-box*.json`.
///
/// A candidate that mentions the app-private config but cannot prove that sequence fails closed.
pub fn plan_runtime_process_cleanup(
    runtime_dir: &str,
    observations: &[RuntimeProcessObservation],
) -> RuntimeProcessCleanupPlan {
    if !is_safe_runtime_dir(runtime_dir) {
        return fail_closed_cleanup();
    }

    let mut terminate = Vec::new();
    let mut seen = std::collections::BTreeSet::new();

    for observation in observations {
        if !valid_observation_identity(observation, &mut seen) {
            return fail_closed_cleanup();
        }

        let mentions_owned_config = observation
            .argv
            .iter()
            .any(|arg| is_owned_config_path(runtime_dir, arg));
        let mentions_runtime_binary = observation.argv.iter().any(|arg| is_runtime_binary(arg));
        let owned = exact_owned_config(runtime_dir, observation).is_some();

        if owned {
            if observation.unsafe_argv {
                return fail_closed_cleanup();
            }
            terminate.push(RuntimeProcessTerminationTarget {
                pid: observation.pid,
                cmdline_digest: observation.cmdline_digest.clone(),
            });
            continue;
        }

        // A truncated runtime-binary candidate or any process referring to this app's private
        // config without the exact launch sequence is ambiguous. Never silently classify it as
        // foreign and never authorize a kill.
        if mentions_owned_config
            || (mentions_runtime_binary && (observation.truncated || observation.unsafe_argv))
        {
            return fail_closed_cleanup();
        }
    }

    if terminate.is_empty() {
        RuntimeProcessCleanupPlan {
            decision: RuntimeProcessCleanupDecision::Clean,
            terminate,
        }
    } else {
        RuntimeProcessCleanupPlan {
            decision: RuntimeProcessCleanupDecision::TerminateOwned,
            terminate,
        }
    }
}

/// Resolve the one exact process serving the current generation.
///
/// The launcher PID is deliberately not an input. Android/root supplies only bounded process
/// observations; this owner binds the accepted current PID to the exact current config path. Any
/// app-owned sibling, duplicate current process, malformed app-private candidate, or ambiguous
/// snapshot fails closed instead of allowing listener reachability to publish a false RUNNING.
pub fn resolve_current_runtime_process(
    runtime_dir: &str,
    current_config_path: &str,
    observations: &[RuntimeProcessObservation],
) -> RuntimeCurrentProcessResolution {
    if !is_safe_runtime_dir(runtime_dir) || !is_owned_config_path(runtime_dir, current_config_path) {
        return fail_closed_resolution();
    }

    let mut seen = std::collections::BTreeSet::new();
    let mut current = Vec::new();
    let mut stale_owned = false;

    for observation in observations {
        if !valid_observation_identity(observation, &mut seen) {
            return fail_closed_resolution();
        }

        let mentions_owned_config = observation
            .argv
            .iter()
            .any(|arg| is_owned_config_path(runtime_dir, arg));
        let mentions_runtime_binary = observation.argv.iter().any(|arg| is_runtime_binary(arg));
        let owned_config = exact_owned_config(runtime_dir, observation);

        if let Some(config) = owned_config {
            if observation.unsafe_argv {
                return fail_closed_resolution();
            }
            if config == current_config_path {
                current.push(RuntimeProcessIdentity {
                    pid: observation.pid,
                    cmdline_digest: observation.cmdline_digest.clone(),
                });
            } else {
                stale_owned = true;
            }
            continue;
        }

        if mentions_owned_config
            || (mentions_runtime_binary && (observation.truncated || observation.unsafe_argv))
        {
            return fail_closed_resolution();
        }
    }

    if stale_owned || current.len() > 1 {
        return RuntimeCurrentProcessResolution {
            decision: RuntimeCurrentProcessDecision::Conflict,
            current: None,
        };
    }

    match current.pop() {
        Some(identity) => RuntimeCurrentProcessResolution {
            decision: RuntimeCurrentProcessDecision::Exact,
            current: Some(identity),
        },
        None => RuntimeCurrentProcessResolution {
            decision: RuntimeCurrentProcessDecision::Absent,
            current: None,
        },
    }
}

fn valid_observation_identity(
    observation: &RuntimeProcessObservation,
    seen: &mut std::collections::BTreeSet<u64>,
) -> bool {
    observation.pid != 0
        && is_sha256_hex(&observation.cmdline_digest)
        && seen.insert(observation.pid)
}

fn exact_owned_config<'a>(
    runtime_dir: &str,
    observation: &'a RuntimeProcessObservation,
) -> Option<&'a str> {
    observation.argv.windows(4).find_map(|window| {
        (is_runtime_binary(&window[0])
            && window[1] == "run"
            && window[2] == "-c"
            && is_owned_config_path(runtime_dir, &window[3]))
        .then_some(window[3].as_str())
    })
}

fn fail_closed_cleanup() -> RuntimeProcessCleanupPlan {
    RuntimeProcessCleanupPlan {
        decision: RuntimeProcessCleanupDecision::FailClosed,
        terminate: Vec::new(),
    }
}

fn fail_closed_resolution() -> RuntimeCurrentProcessResolution {
    RuntimeCurrentProcessResolution {
        decision: RuntimeCurrentProcessDecision::FailClosed,
        current: None,
    }
}

fn is_runtime_binary(arg: &str) -> bool {
    arg.ends_with(&format!("/{SING_BOX_LIBRARY}"))
}

fn is_owned_config_path(runtime_dir: &str, arg: &str) -> bool {
    let Some(name) = arg
        .strip_prefix(runtime_dir)
        .and_then(|tail| tail.strip_prefix('/'))
    else {
        return false;
    };
    if name == LEGACY_CONFIG_FILE {
        return true;
    }
    let Some(generation) = name
        .strip_prefix("sing-box-")
        .and_then(|tail| tail.strip_suffix(".json"))
    else {
        return false;
    };
    generation.len() == GENERATION_ID_LENGTH
        && generation
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn is_safe_runtime_dir(path: &str) -> bool {
    path.starts_with('/')
        && !path.ends_with('/')
        && path.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'_' | b'.' | b'~' | b'=' | b'-')
        })
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
mod tests {
    use super::*;

    const RUNTIME: &str = "/data/user/0/com.mobileproxymish.app.debug/no_backup/proxy-runtime";
    const DIGEST: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn observation(pid: u64, argv: &[&str]) -> RuntimeProcessObservation {
        RuntimeProcessObservation {
            pid,
            argv: argv.iter().map(|value| (*value).to_string()).collect(),
            cmdline_digest: DIGEST.to_string(),
            truncated: false,
            unsafe_argv: false,
        }
    }

    fn current_config() -> String {
        format!("{RUNTIME}/sing-box-abcdefghijklmnopqrstuvwx.json")
    }

    #[test]
    fn exact_owned_process_is_terminated() {
        let config = current_config();
        let plan = plan_runtime_process_cleanup(
            RUNTIME,
            &[observation(
                42,
                &["/data/app/lib/libsingbox.so", "run", "-c", &config],
            )],
        );
        assert_eq!(plan.decision, RuntimeProcessCleanupDecision::TerminateOwned);
        assert_eq!(plan.terminate.len(), 1);
        assert_eq!(plan.terminate[0].pid, 42);
    }

    #[test]
    fn old_launcher_prefix_does_not_hide_owned_child() {
        let config = current_config();
        let plan = plan_runtime_process_cleanup(
            RUNTIME,
            &[observation(
                77,
                &[
                    "/system/bin/toybox",
                    "nohup",
                    "/old/lib/libsingbox.so",
                    "run",
                    "-c",
                    &config,
                ],
            )],
        );
        assert_eq!(plan.decision, RuntimeProcessCleanupDecision::TerminateOwned);
        assert_eq!(plan.terminate[0].pid, 77);
    }

    #[test]
    fn foreign_sing_box_is_never_terminated() {
        let plan = plan_runtime_process_cleanup(
            RUNTIME,
            &[observation(
                88,
                &[
                    "/data/local/tmp/libsingbox.so",
                    "run",
                    "-c",
                    "/data/local/tmp/foreign.json",
                ],
            )],
        );
        assert_eq!(plan.decision, RuntimeProcessCleanupDecision::Clean);
        assert!(plan.terminate.is_empty());
    }

    #[test]
    fn malformed_app_private_candidate_fails_closed() {
        let config = current_config();
        let plan = plan_runtime_process_cleanup(
            RUNTIME,
            &[observation(99, &["/system/bin/sh", "-c", &config])],
        );
        assert_eq!(plan.decision, RuntimeProcessCleanupDecision::FailClosed);
        assert!(plan.terminate.is_empty());
    }

    #[test]
    fn duplicate_pid_or_invalid_digest_fails_closed() {
        let config = current_config();
        let one = observation(101, &["/data/app/lib/libsingbox.so", "run", "-c", &config]);
        let mut bad = one.clone();
        bad.cmdline_digest = "not-a-digest".to_string();
        assert_eq!(
            plan_runtime_process_cleanup(RUNTIME, &[bad]).decision,
            RuntimeProcessCleanupDecision::FailClosed
        );
        assert_eq!(
            plan_runtime_process_cleanup(RUNTIME, &[one.clone(), one]).decision,
            RuntimeProcessCleanupDecision::FailClosed
        );
    }

    #[test]
    fn truncated_runtime_candidate_fails_closed() {
        let mut candidate = observation(202, &["/old/lib/libsingbox.so", "run"]);
        candidate.truncated = true;
        assert_eq!(
            plan_runtime_process_cleanup(RUNTIME, &[candidate]).decision,
            RuntimeProcessCleanupDecision::FailClosed
        );
    }

    #[test]
    fn current_process_resolution_uses_exact_current_config_not_launcher_pid() {
        let config = current_config();
        let resolution = resolve_current_runtime_process(
            RUNTIME,
            &config,
            &[observation(
                303,
                &[
                    "/system/bin/toybox",
                    "nohup",
                    "/data/app/lib/libsingbox.so",
                    "run",
                    "-c",
                    &config,
                ],
            )],
        );
        assert_eq!(resolution.decision, RuntimeCurrentProcessDecision::Exact);
        assert_eq!(resolution.current.expect("exact current process").pid, 303);
    }

    #[test]
    fn current_process_resolution_ignores_foreign_and_reports_absent() {
        let config = current_config();
        let resolution = resolve_current_runtime_process(
            RUNTIME,
            &config,
            &[observation(
                404,
                &[
                    "/data/local/tmp/libsingbox.so",
                    "run",
                    "-c",
                    "/data/local/tmp/foreign.json",
                ],
            )],
        );
        assert_eq!(resolution.decision, RuntimeCurrentProcessDecision::Absent);
        assert!(resolution.current.is_none());
    }

    #[test]
    fn stale_owned_sibling_or_duplicate_current_is_conflict() {
        let current = current_config();
        let stale = format!("{RUNTIME}/sing-box-zyxwvutsrqponmlkjihgfedc.json");
        let current_observation = observation(
            505,
            &["/data/app/lib/libsingbox.so", "run", "-c", &current],
        );
        let stale_observation = observation(
            506,
            &["/data/app/lib/libsingbox.so", "run", "-c", &stale],
        );
        assert_eq!(
            resolve_current_runtime_process(
                RUNTIME,
                &current,
                &[current_observation.clone(), stale_observation],
            )
            .decision,
            RuntimeCurrentProcessDecision::Conflict
        );

        let mut duplicate = current_observation.clone();
        duplicate.pid = 507;
        assert_eq!(
            resolve_current_runtime_process(RUNTIME, &current, &[current_observation, duplicate])
                .decision,
            RuntimeCurrentProcessDecision::Conflict
        );
    }

    #[test]
    fn ambiguous_current_candidate_fails_closed() {
        let config = current_config();
        let resolution = resolve_current_runtime_process(
            RUNTIME,
            &config,
            &[observation(606, &["/system/bin/sh", "-c", &config])],
        );
        assert_eq!(
            resolution.decision,
            RuntimeCurrentProcessDecision::FailClosed
        );
        assert!(resolution.current.is_none());
    }
}