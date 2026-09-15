use mish_runtime::{
    RuntimeCurrentProcessDecision as OwnerCurrentProcessDecision,
    RuntimeProcessCleanupDecision as OwnerCleanupDecision,
    RuntimeProcessObservation as OwnerProcessObservation,
    plan_runtime_process_cleanup as owner_plan_runtime_process_cleanup,
    resolve_current_runtime_process as owner_resolve_current_runtime_process,
};

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RuntimeProcessObservationView {
    pub pid: u64,
    pub argv: Vec<String>,
    pub cmdline_digest: String,
    pub truncated: bool,
    pub unsafe_argv: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RuntimeProcessCleanupDecision {
    Clean,
    TerminateOwned,
    FailClosed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RuntimeProcessTerminationTargetView {
    pub pid: u64,
    pub cmdline_digest: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RuntimeProcessCleanupPlanView {
    pub decision: RuntimeProcessCleanupDecision,
    pub terminate: Vec<RuntimeProcessTerminationTargetView>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RuntimeCurrentProcessDecision {
    Exact,
    Absent,
    Conflict,
    FailClosed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RuntimeProcessIdentityView {
    pub pid: u64,
    pub cmdline_digest: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RuntimeCurrentProcessResolutionView {
    pub decision: RuntimeCurrentProcessDecision,
    pub current: Option<RuntimeProcessIdentityView>,
}

fn project_observation(observation: RuntimeProcessObservationView) -> OwnerProcessObservation {
    OwnerProcessObservation {
        pid: observation.pid,
        argv: observation.argv,
        cmdline_digest: observation.cmdline_digest,
        truncated: observation.truncated,
        unsafe_argv: observation.unsafe_argv,
    }
}

/// Thin typed projection of the vendor-neutral process reconciliation natural owner.
#[uniffi::export]
pub fn plan_runtime_process_cleanup(
    runtime_dir: String,
    observations: Vec<RuntimeProcessObservationView>,
) -> RuntimeProcessCleanupPlanView {
    let owner_observations = observations
        .into_iter()
        .map(project_observation)
        .collect::<Vec<_>>();
    let plan = owner_plan_runtime_process_cleanup(&runtime_dir, &owner_observations);
    RuntimeProcessCleanupPlanView {
        decision: match plan.decision {
            OwnerCleanupDecision::Clean => RuntimeProcessCleanupDecision::Clean,
            OwnerCleanupDecision::TerminateOwned => RuntimeProcessCleanupDecision::TerminateOwned,
            OwnerCleanupDecision::FailClosed => RuntimeProcessCleanupDecision::FailClosed,
        },
        terminate: plan
            .terminate
            .into_iter()
            .map(|target| RuntimeProcessTerminationTargetView {
                pid: target.pid,
                cmdline_digest: target.cmdline_digest,
            })
            .collect(),
    }
}

/// Resolve the exact process serving the current generation through the same Rust owner.
#[uniffi::export]
pub fn resolve_current_runtime_process(
    runtime_dir: String,
    current_config_path: String,
    observations: Vec<RuntimeProcessObservationView>,
) -> RuntimeCurrentProcessResolutionView {
    let owner_observations = observations
        .into_iter()
        .map(project_observation)
        .collect::<Vec<_>>();
    let resolution = owner_resolve_current_runtime_process(
        &runtime_dir,
        &current_config_path,
        &owner_observations,
    );
    RuntimeCurrentProcessResolutionView {
        decision: match resolution.decision {
            OwnerCurrentProcessDecision::Exact => RuntimeCurrentProcessDecision::Exact,
            OwnerCurrentProcessDecision::Absent => RuntimeCurrentProcessDecision::Absent,
            OwnerCurrentProcessDecision::Conflict => RuntimeCurrentProcessDecision::Conflict,
            OwnerCurrentProcessDecision::FailClosed => RuntimeCurrentProcessDecision::FailClosed,
        },
        current: resolution
            .current
            .map(|identity| RuntimeProcessIdentityView {
                pid: identity.pid,
                cmdline_digest: identity.cmdline_digest,
            }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn current_observation(runtime: &str, pid: u64) -> RuntimeProcessObservationView {
        RuntimeProcessObservationView {
            pid,
            argv: vec![
                "/old/lib/libsingbox.so".into(),
                "run".into(),
                "-c".into(),
                format!("{runtime}/sing-box-abcdefghijklmnopqrstuvwx.json"),
            ],
            cmdline_digest: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                .into(),
            truncated: false,
            unsafe_argv: false,
        }
    }

    #[test]
    fn ffi_projection_keeps_process_identity_decision_in_runtime_owner() {
        let runtime = "/data/user/0/pkg/no_backup/proxy-runtime".to_string();
        let plan =
            plan_runtime_process_cleanup(runtime.clone(), vec![current_observation(&runtime, 42)]);
        assert_eq!(plan.decision, RuntimeProcessCleanupDecision::TerminateOwned);
        assert_eq!(plan.terminate.len(), 1);
        assert_eq!(plan.terminate[0].pid, 42);
    }

    #[test]
    fn ffi_projects_exact_current_process_from_runtime_owner() {
        let runtime = "/data/user/0/pkg/no_backup/proxy-runtime".to_string();
        let current_config = format!("{runtime}/sing-box-abcdefghijklmnopqrstuvwx.json");
        let resolution = resolve_current_runtime_process(
            runtime.clone(),
            current_config,
            vec![current_observation(&runtime, 77)],
        );
        assert_eq!(resolution.decision, RuntimeCurrentProcessDecision::Exact);
        assert_eq!(resolution.current.expect("current identity").pid, 77);
    }
}
