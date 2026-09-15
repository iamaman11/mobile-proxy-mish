use mish_runtime::{
    RuntimeProcessCleanupDecision as OwnerCleanupDecision,
    RuntimeProcessObservation as OwnerProcessObservation,
    plan_runtime_process_cleanup as owner_plan_runtime_process_cleanup,
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

/// Thin typed projection of the vendor-neutral process reconciliation natural owner.
#[uniffi::export]
pub fn plan_runtime_process_cleanup(
    runtime_dir: String,
    observations: Vec<RuntimeProcessObservationView>,
) -> RuntimeProcessCleanupPlanView {
    let owner_observations = observations
        .into_iter()
        .map(|observation| OwnerProcessObservation {
            pid: observation.pid,
            argv: observation.argv,
            cmdline_digest: observation.cmdline_digest,
            truncated: observation.truncated,
            unsafe_argv: observation.unsafe_argv,
        })
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_projection_keeps_process_identity_decision_in_runtime_owner() {
        let runtime = "/data/user/0/pkg/no_backup/proxy-runtime".to_string();
        let plan = plan_runtime_process_cleanup(
            runtime.clone(),
            vec![RuntimeProcessObservationView {
                pid: 42,
                argv: vec![
                    "/old/lib/libsingbox.so".into(),
                    "run".into(),
                    "-c".into(),
                    format!("{runtime}/sing-box-abcdefghijklmnopqrstuvwx.json"),
                ],
                cmdline_digest:
                    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                        .into(),
                truncated: false,
                unsafe_argv: false,
            }],
        );
        assert_eq!(
            plan.decision,
            RuntimeProcessCleanupDecision::TerminateOwned
        );
        assert_eq!(plan.terminate.len(), 1);
        assert_eq!(plan.terminate[0].pid, 42);
    }
}
