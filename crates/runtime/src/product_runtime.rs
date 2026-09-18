//! Stable PRODUCT process handle with Rust-owned runtime generation lifecycle.
//!
//! One process keeps one Tokio executor. Runtime generations are immutable composition aggregates
//! replaced inside this owner. Android may register platform observations against the stable handle;
//! it never constructs, numbers or replaces PRODUCT generations.

use crate::{
    CellularDnsResolver, CellularPolicyObserver, ProductGeneration, ProxyRuntimeObserver,
    ReadinessObserver, RuntimeExecutionError, RuntimeExecutor, RuntimeLifecycle,
    RuntimeLifecycleState, RuntimeStartAction, RuntimeStopAction,
};
use mish_cellular::{
    CellularAdmissionSnapshot, NetworkHandle, NetworkObservation, RootPolicyNamespace,
};
use mish_transport::{MeshTransportError, MeshTransportSnapshot, MeshVpnObservation};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::task::spawn_blocking;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProductRuntimeSnapshot {
    pub state: RuntimeLifecycleState,
    pub generation: u64,
    pub generation_requires_replacement: bool,
}

#[derive(Clone)]
struct ProductStartInput {
    credential_version: Option<u64>,
    username: Option<String>,
    password: Option<String>,
}

#[derive(Clone, Default)]
struct ProductObservers {
    cellular: Option<CellularPolicyObserver>,
    readiness: Option<ReadinessObserver>,
    proxy: Option<ProxyRuntimeObserver>,
}

#[derive(Clone)]
struct StoredCellularObservation {
    sequence: u64,
    observation: NetworkObservation,
    observed_handle: NetworkHandle,
    interface_name: Option<String>,
}

#[derive(Clone)]
struct StoredMeshObservation {
    sequence: u64,
    observation: MeshVpnObservation,
}

#[derive(Clone, Default)]
struct ProductPlatformFacts {
    cellular: HashMap<NetworkHandle, StoredCellularObservation>,
    last_cellular_sequence: Option<u64>,
    last_cellular_loss: Option<(u64, NetworkHandle)>,
    mesh: Option<StoredMeshObservation>,
}

impl ProductPlatformFacts {
    fn record_cellular_observation(
        &mut self,
        sequence: u64,
        observation: NetworkObservation,
        observed_handle: NetworkHandle,
        interface_name: Option<String>,
    ) {
        if self
            .last_cellular_sequence
            .is_some_and(|last| sequence <= last)
        {
            return;
        }
        self.last_cellular_sequence = Some(sequence);
        self.last_cellular_loss = None;
        self.cellular.insert(
            observed_handle,
            StoredCellularObservation {
                sequence,
                observation,
                observed_handle,
                interface_name,
            },
        );
    }

    fn record_cellular_loss(&mut self, sequence: u64, observed_handle: NetworkHandle) {
        if self
            .last_cellular_sequence
            .is_some_and(|last| sequence <= last)
        {
            return;
        }
        self.last_cellular_sequence = Some(sequence);
        self.last_cellular_loss = Some((sequence, observed_handle));
        self.cellular.remove(&observed_handle);
    }

    fn record_mesh(&mut self, sequence: u64, observation: MeshVpnObservation) {
        if self
            .mesh
            .as_ref()
            .is_some_and(|current| sequence <= current.sequence)
        {
            return;
        }
        self.mesh = Some(StoredMeshObservation {
            sequence,
            observation,
        });
    }

    fn cellular_replay(&self) -> Vec<StoredCellularObservation> {
        let mut observations = self.cellular.values().cloned().collect::<Vec<_>>();
        observations.sort_by_key(|observation| observation.sequence);
        observations
    }

    fn clear_cellular(&mut self) {
        self.cellular.clear();
        self.last_cellular_sequence = None;
        self.last_cellular_loss = None;
    }

    fn clear_mesh(&mut self) {
        self.mesh = None;
    }
}

struct ProductRuntimeState {
    lifecycle: RuntimeLifecycle,
    generation: Arc<ProductGeneration>,
    pending_start: Option<ProductStartInput>,
    observers: ProductObservers,
    platform_facts: ProductPlatformFacts,
    platform_mutation_epoch: u64,
    active_platform_mutation: Option<u64>,
    closed: bool,
}

pub struct ProductRuntimeCoordinator {
    executor: Arc<RuntimeExecutor>,
    resolver: Arc<dyn CellularDnsResolver>,
    product_uid: u32,
    namespace: RootPolicyNamespace,
    observer_generation: Arc<AtomicU64>,
    state: Mutex<ProductRuntimeState>,
}

impl ProductRuntimeCoordinator {
    pub fn new(
        resolver: Arc<dyn CellularDnsResolver>,
        product_uid: u32,
        namespace: RootPolicyNamespace,
    ) -> Result<Arc<Self>, RuntimeExecutionError> {
        if product_uid == 0 {
            return Err(RuntimeExecutionError::StateUnavailable);
        }

        let executor = RuntimeExecutor::new()?;
        let lifecycle = RuntimeLifecycle::new();
        let generation = ProductGeneration::new(
            Arc::clone(&executor),
            Arc::clone(&resolver),
            product_uid,
            namespace,
            lifecycle.generation(),
        )?;

        Ok(Arc::new(Self {
            executor,
            resolver,
            product_uid,
            namespace,
            observer_generation: Arc::new(AtomicU64::new(lifecycle.generation())),
            state: Mutex::new(ProductRuntimeState {
                lifecycle,
                generation,
                pending_start: None,
                observers: ProductObservers::default(),
                platform_facts: ProductPlatformFacts::default(),
                platform_mutation_epoch: 0,
                active_platform_mutation: None,
                closed: false,
            }),
        }))
    }

    pub fn executor(&self) -> Arc<RuntimeExecutor> {
        Arc::clone(&self.executor)
    }

    pub fn snapshot(&self) -> ProductRuntimeSnapshot {
        self.state().map_or(
            ProductRuntimeSnapshot {
                state: RuntimeLifecycleState::Stopped,
                generation: 0,
                generation_requires_replacement: true,
            },
            |state| snapshot(&state),
        )
    }

    pub fn current_generation(&self) -> Result<Arc<ProductGeneration>, RuntimeExecutionError> {
        self.state().map(|state| Arc::clone(&state.generation))
    }

    pub fn active_generation(&self) -> Result<Arc<ProductGeneration>, RuntimeExecutionError> {
        let state = self.state()?;
        if !matches!(
            state.lifecycle.state(),
            RuntimeLifecycleState::Starting | RuntimeLifecycleState::Running
        ) {
            return Err(RuntimeExecutionError::StateUnavailable);
        }
        Ok(Arc::clone(&state.generation))
    }

    pub fn observe_network(
        &self,
        sequence: u64,
        observation: NetworkObservation,
        observed_handle: NetworkHandle,
        interface_name: Option<String>,
    ) -> Result<CellularAdmissionSnapshot, crate::CellularRuntimeError> {
        let generation = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| crate::CellularRuntimeError::StateUnavailable)?;
            state.platform_facts.record_cellular_observation(
                sequence,
                observation,
                observed_handle,
                interface_name.clone(),
            );
            if !matches!(
                state.lifecycle.state(),
                RuntimeLifecycleState::Starting | RuntimeLifecycleState::Running
            ) {
                return Err(crate::CellularRuntimeError::StateUnavailable);
            }
            Arc::clone(&state.generation)
        };
        generation
            .policy()
            .observe_network(observation, observed_handle, interface_name)
    }

    pub fn network_lost(
        &self,
        sequence: u64,
        observed_handle: NetworkHandle,
    ) -> Result<CellularAdmissionSnapshot, crate::CellularRuntimeError> {
        let sequence_value = mish_cellular::ObservationSequence::new(sequence)
            .ok_or(crate::CellularRuntimeError::StateUnavailable)?;
        let generation = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| crate::CellularRuntimeError::StateUnavailable)?;
            state
                .platform_facts
                .record_cellular_loss(sequence, observed_handle);
            if !matches!(
                state.lifecycle.state(),
                RuntimeLifecycleState::Starting | RuntimeLifecycleState::Running
            ) {
                return Err(crate::CellularRuntimeError::StateUnavailable);
            }
            Arc::clone(&state.generation)
        };
        generation
            .policy()
            .network_lost(sequence_value, observed_handle)
    }

    pub fn observe_mesh_vpn(
        &self,
        sequence: u64,
        observation: MeshVpnObservation,
    ) -> Result<MeshTransportSnapshot, MeshTransportError> {
        let generation = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| MeshTransportError::StateUnavailable)?;
            state
                .platform_facts
                .record_mesh(sequence, observation.clone());
            if !matches!(
                state.lifecycle.state(),
                RuntimeLifecycleState::Starting | RuntimeLifecycleState::Running
            ) {
                return Err(MeshTransportError::StateUnavailable);
            }
            Arc::clone(&state.generation)
        };
        apply_mesh_observation(&generation, sequence, observation)
    }

    pub fn invalidate_cellular_platform_facts(&self) -> Result<(), RuntimeExecutionError> {
        self.state_mut()?.platform_facts.clear_cellular();
        Ok(())
    }

    pub fn invalidate_mesh_platform_fact(&self) -> Result<(), RuntimeExecutionError> {
        self.state_mut()?.platform_facts.clear_mesh();
        Ok(())
    }

    pub fn set_cellular_observer(&self, observer: CellularPolicyObserver) {
        let generation = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.observers.cellular = Some(Arc::clone(&observer));
            Arc::clone(&state.generation)
        };
        bind_cellular_observer(
            &generation,
            observer,
            Arc::clone(&self.observer_generation),
        );
    }

    pub fn set_readiness_observer(&self, observer: ReadinessObserver) {
        let generation = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.observers.readiness = Some(Arc::clone(&observer));
            Arc::clone(&state.generation)
        };
        bind_readiness_observer(
            &generation,
            observer,
            Arc::clone(&self.observer_generation),
        );
    }

    pub fn set_proxy_observer(&self, observer: ProxyRuntimeObserver) {
        let generation = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.observers.proxy = Some(Arc::clone(&observer));
            Arc::clone(&state.generation)
        };
        bind_proxy_observer(
            &generation,
            observer,
            Arc::clone(&self.observer_generation),
        );
    }

    pub fn request_start(
        self: &Arc<Self>,
        credential_version: Option<u64>,
        username: Option<String>,
        password: Option<String>,
    ) -> Result<RuntimeStartAction, RuntimeExecutionError> {
        let input = ProductStartInput {
            credential_version,
            username,
            password,
        };

        let (action, expected_generation, rebound) = {
            let mut state = self.state_mut()?;
            if state.closed || state.active_platform_mutation.is_some() {
                return Err(RuntimeExecutionError::StateUnavailable);
            }

            let action = state.lifecycle.request_start();
            match action {
                RuntimeStartAction::AlreadyActive => return Ok(action),
                RuntimeStartAction::QueuedAfterStop => {
                    state.pending_start = Some(input);
                    return Ok(action);
                }
                RuntimeStartAction::StartNow => {}
            }

            let rebound = if state.lifecycle.generation_requires_replacement() {
                if !state.lifecycle.take_generation_replacement_for_start() {
                    state.lifecycle.start_submission_failed();
                    return Err(RuntimeExecutionError::StateUnavailable);
                }
                let generation = match self.build_generation(state.lifecycle.generation()) {
                    Ok(generation) => generation,
                    Err(error) => {
                        state.lifecycle.start_submission_failed();
                        state.lifecycle.mark_stopped_generation_dirty();
                        return Err(error);
                    }
                };
                state.generation = Arc::clone(&generation);
            self.observer_generation
                .store(generation.generation(), Ordering::Release);
                Some((generation, state.observers.clone()))
            } else {
                None
            };
            state.pending_start = None;
            (action, state.lifecycle.generation(), rebound)
        };

        if let Some((generation, observers)) = rebound {
            bind_observers(
                &generation,
                observers,
                Arc::clone(&self.observer_generation),
            );
        }

        let owner = Arc::clone(self);
        if self
            .executor
            .spawn(async move {
                owner.run_start(expected_generation, input).await;
            })
            .is_err()
        {
            if let Ok(mut state) = self.state.lock() {
                state.lifecycle.start_submission_failed();
            }
            return Err(RuntimeExecutionError::ThreadUnavailable);
        }
        Ok(action)
    }

    /// Begins one stopped-only Android platform mutation transaction.
    ///
    /// While the lease is active, explicit runtime start fails closed. This closes the previous
    /// snapshot(STOPPED) -> platform mutation -> generation advance TOCTOU window without moving
    /// Android Keystore/storage mechanics into Rust.
    pub fn begin_stopped_platform_mutation(
        &self,
    ) -> Result<Option<u64>, RuntimeExecutionError> {
        let mut state = self.state_mut()?;
        if state.closed
            || state.active_platform_mutation.is_some()
            || !state.lifecycle.can_mutate_stopped_generation()
        {
            return Ok(None);
        }
        let Some(next) = state.platform_mutation_epoch.checked_add(1) else {
            state.lifecycle.mark_stopped_generation_dirty();
            return Ok(None);
        };
        state.platform_mutation_epoch = next;
        state.active_platform_mutation = Some(next);
        Ok(Some(next))
    }

    /// Completes one exact stopped-only platform mutation lease.
    ///
    /// A failed/uncertain Android effect marks the stopped generation dirty. A successful effect
    /// advances generation identity and installs a fresh native generation under this same stable
    /// process handle.
    pub fn complete_stopped_platform_mutation(
        &self,
        lease: u64,
        succeeded: bool,
    ) -> Result<bool, RuntimeExecutionError> {
        let rebound = {
            let mut state = self.state_mut()?;
            if state.closed || state.active_platform_mutation != Some(lease) {
                return Ok(false);
            }
            state.active_platform_mutation = None;

            if !succeeded || !state.lifecycle.can_mutate_stopped_generation() {
                state.lifecycle.mark_stopped_generation_dirty();
                return Ok(false);
            }
            if !state.lifecycle.advance_stopped_generation() {
                state.lifecycle.mark_stopped_generation_dirty();
                return Ok(false);
            }

            let generation = match self.build_generation(state.lifecycle.generation()) {
                Ok(generation) => generation,
                Err(_) => {
                    state.lifecycle.mark_stopped_generation_dirty();
                    return Ok(false);
                }
            };
            state.generation = Arc::clone(&generation);
                self.observer_generation
                    .store(generation.generation(), Ordering::Release);
            (generation, state.observers.clone())
        };
        bind_observers(
            &rebound.0,
            rebound.1,
            Arc::clone(&self.observer_generation),
        );
        Ok(true)
    }

    pub fn request_stop(
        self: &Arc<Self>,
    ) -> Result<RuntimeStopAction, RuntimeExecutionError> {
        let (action, expected_generation) = {
            let mut state = self.state_mut()?;
            if state.closed {
                return Ok(RuntimeStopAction::AlreadyStopped);
            }
            let action = state.lifecycle.request_stop();
            if action != RuntimeStopAction::StopNow {
                return Ok(action);
            }
            (action, state.lifecycle.generation())
        };

        let owner = Arc::clone(self);
        if self
            .executor
            .spawn(async move {
                owner.run_stop(expected_generation).await;
            })
            .is_err()
        {
            if let Ok(mut state) = self.state.lock() {
                state.lifecycle.stop_submission_failed();
            }
            return Err(RuntimeExecutionError::ThreadUnavailable);
        }
        Ok(action)
    }

    /// Final process teardown. Unlike service stop, this destroys the shared Tokio runtime.
    pub fn shutdown_blocking(self: &Arc<Self>) -> Result<bool, RuntimeExecutionError> {
        let already_closed = {
            let mut state = self.state_mut()?;
            if state.closed {
                true
            } else {
                state.closed = true;
                state.pending_start = None;
                false
            }
        };
        if already_closed {
            return Ok(true);
        }

        let generation = self.current_generation()?;
        let clean = self.executor.block_on(generation.shutdown_async())?;
        self.executor.shutdown()?;
        Ok(clean)
    }

    async fn run_start(self: Arc<Self>, expected_generation: u64, input: ProductStartInput) {
        let (generation, platform_facts) = {
            let Ok(state) = self.state.lock() else {
                return;
            };
            if state.closed
                || state.lifecycle.state() != RuntimeLifecycleState::Starting
                || state.lifecycle.generation() != expected_generation
                || state.generation.generation() != expected_generation
            {
                return;
            }
            (
                Arc::clone(&state.generation),
                state.platform_facts.clone(),
            )
        };

        if generation.policy().start().is_err()
            || !replay_platform_facts(&generation, &platform_facts)
        {
            self.finish_failed_start(expected_generation, generation).await;
            return;
        }

        let proxy = generation.proxy();
        let input_for_proxy = input.clone();
        let proxy_started = spawn_blocking(move || {
            proxy.start(
                input_for_proxy.credential_version,
                input_for_proxy.username,
                input_for_proxy.password,
            );
        })
        .await
        .is_ok();

        if !proxy_started {
            self.finish_failed_start(expected_generation, generation).await;
            return;
        }

        if let Ok(mut state) = self.state.lock() {
            if state.lifecycle.generation() == expected_generation
                && state.lifecycle.state() == RuntimeLifecycleState::Starting
            {
                state.lifecycle.complete_start(true, true);
            }
        }
    }

    async fn finish_failed_start(
        &self,
        expected_generation: u64,
        generation: Arc<ProductGeneration>,
    ) {
        let clean = generation.shutdown_async().await;
        let rebound = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.lifecycle.generation() != expected_generation
                || state.lifecycle.state() != RuntimeLifecycleState::Starting
            {
                return;
            }
            let completion = state.lifecycle.complete_start(false, clean);
            if completion.install_fresh_generation_now() {
                match self.build_generation(state.lifecycle.generation()) {
                    Ok(fresh) => {
                        state.generation = Arc::clone(&fresh);
                        self.observer_generation
                            .store(fresh.generation(), Ordering::Release);
                        Some((fresh, state.observers.clone()))
                    }
                    Err(_) => {
                        state.lifecycle.mark_stopped_generation_dirty();
                        None
                    }
                }
            } else {
                None
            }
        };
        if let Some((generation, observers)) = rebound {
            bind_observers(
                &generation,
                observers,
                Arc::clone(&self.observer_generation),
            );
        }
    }

    async fn run_stop(self: Arc<Self>, expected_generation: u64) {
        let generation = {
            let Ok(state) = self.state.lock() else {
                return;
            };
            if state.lifecycle.generation() != expected_generation
                || state.lifecycle.state() != RuntimeLifecycleState::Stopping
            {
                return;
            }
            Arc::clone(&state.generation)
        };

        let clean = generation.shutdown_async().await;

        let (rebound, restart) = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.lifecycle.generation() != expected_generation
                || state.lifecycle.state() != RuntimeLifecycleState::Stopping
            {
                return;
            }

            let disposition = state.lifecycle.complete_stop(clean);
            let mut rebound = None;
            if disposition.install_fresh_generation_now() {
                match self.build_generation(state.lifecycle.generation()) {
                    Ok(fresh) => {
                        state.generation = Arc::clone(&fresh);
                        self.observer_generation
                            .store(fresh.generation(), Ordering::Release);
                        rebound = Some((fresh, state.observers.clone()));
                    }
                    Err(_) => {
                        state.lifecycle.mark_stopped_generation_dirty();
                    }
                }
            }

            let restart = if disposition.restart_now() && rebound.is_some() {
                state.pending_start.take()
            } else {
                state.pending_start = None;
                None
            };
            (rebound, restart)
        };

        if let Some((generation, observers)) = rebound {
            bind_observers(
                &generation,
                observers,
                Arc::clone(&self.observer_generation),
            );
        }

        if let Some(input) = restart {
            let expected = {
                let Ok(mut state) = self.state.lock() else {
                    return;
                };
                if state.lifecycle.request_start() != RuntimeStartAction::StartNow {
                    return;
                }
                state.lifecycle.generation()
            };
            self.run_start(expected, input).await;
        }
    }

    fn build_generation(
        &self,
        generation: u64,
    ) -> Result<Arc<ProductGeneration>, RuntimeExecutionError> {
        ProductGeneration::new(
            Arc::clone(&self.executor),
            Arc::clone(&self.resolver),
            self.product_uid,
            self.namespace,
            generation,
        )
    }

    fn state(&self) -> Result<MutexGuard<'_, ProductRuntimeState>, RuntimeExecutionError> {
        self.state
            .lock()
            .map_err(|_| RuntimeExecutionError::StateUnavailable)
    }

    fn state_mut(&self) -> Result<MutexGuard<'_, ProductRuntimeState>, RuntimeExecutionError> {
        self.state()
    }
}

fn replay_platform_facts(
    generation: &ProductGeneration,
    platform_facts: &ProductPlatformFacts,
) -> bool {
    let cellular = platform_facts.cellular_replay();
    for observation in cellular.iter().cloned() {
        if generation
            .policy()
            .observe_network(
                observation.observation,
                observation.observed_handle,
                observation.interface_name,
            )
            .is_err()
        {
            return false;
        }
    }
    if cellular.is_empty() {
        if let Some((sequence, handle)) = platform_facts.last_cellular_loss {
            let Some(sequence) = mish_cellular::ObservationSequence::new(sequence) else {
                return false;
            };
            if generation.policy().network_lost(sequence, handle).is_err() {
                return false;
            }
        }
    }

    if let Some(mesh) = platform_facts.mesh.clone() {
        if apply_mesh_observation(generation, mesh.sequence, mesh.observation).is_err() {
            return false;
        }
    }
    true
}

fn apply_mesh_observation(
    generation: &ProductGeneration,
    sequence: u64,
    observation: MeshVpnObservation,
) -> Result<MeshTransportSnapshot, MeshTransportError> {
    let snapshot = generation.mesh().observe_vpn(sequence, observation)?;
    generation
        .readiness()
        .observe_mesh(snapshot)
        .map_err(|_| MeshTransportError::StateUnavailable)?;
    generation.mesh().snapshot()
}

fn bind_observers(
    generation: &ProductGeneration,
    observers: ProductObservers,
    observer_generation: Arc<AtomicU64>,
) {
    if let Some(observer) = observers.cellular {
        bind_cellular_observer(generation, observer, Arc::clone(&observer_generation));
    }
    if let Some(observer) = observers.readiness {
        bind_readiness_observer(generation, observer, Arc::clone(&observer_generation));
    }
    if let Some(observer) = observers.proxy {
        bind_proxy_observer(generation, observer, observer_generation);
    }
}

fn bind_cellular_observer(
    generation: &ProductGeneration,
    observer: CellularPolicyObserver,
    observer_generation: Arc<AtomicU64>,
) {
    let expected_generation = generation.generation();
    generation.policy().set_observer(Arc::new(move |publication| {
        if observer_generation.load(Ordering::Acquire) == expected_generation {
            observer(publication);
        }
    }));
}

fn bind_readiness_observer(
    generation: &ProductGeneration,
    observer: ReadinessObserver,
    observer_generation: Arc<AtomicU64>,
) {
    let expected_generation = generation.generation();
    generation.readiness().set_observer(Arc::new(move |readiness| {
        if observer_generation.load(Ordering::Acquire) == expected_generation {
            observer(readiness);
        }
    }));
}

fn bind_proxy_observer(
    generation: &ProductGeneration,
    observer: ProxyRuntimeObserver,
    observer_generation: Arc<AtomicU64>,
) {
    let expected_generation = generation.generation();
    generation.proxy().set_observer(Arc::new(move |publication| {
        if observer_generation.load(Ordering::Acquire) == expected_generation {
            observer(publication);
        }
    }));
}

fn snapshot(state: &ProductRuntimeState) -> ProductRuntimeSnapshot {
    ProductRuntimeSnapshot {
        state: state.lifecycle.state(),
        generation: state.lifecycle.generation(),
        generation_requires_replacement: state.lifecycle.generation_requires_replacement(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_proxy::ProxyOutboundConnectError;
    use std::net::IpAddr;

    struct EmptyResolver;

    impl CellularDnsResolver for EmptyResolver {
        fn resolve(
            &self,
            _authority: mish_cellular::CellularNetworkAuthority,
            _hostname: &str,
        ) -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
            Err(ProxyOutboundConnectError::Unavailable)
        }
    }

    #[test]
    fn stable_process_handle_starts_at_generation_one() {
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");
        let snapshot = runtime.snapshot();
        assert_eq!(snapshot.state, RuntimeLifecycleState::Stopped);
        assert_eq!(snapshot.generation, 1);
        assert!(!snapshot.generation_requires_replacement);
        runtime.executor.shutdown().expect("executor shutdown");
    }

    #[test]
    fn duplicate_start_is_owned_by_native_lifecycle() {
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");
        assert_eq!(
            runtime
                .request_start(None, None, None)
                .expect("first start"),
            RuntimeStartAction::StartNow
        );
        assert_eq!(
            runtime
                .request_start(None, None, None)
                .expect("duplicate start"),
            RuntimeStartAction::AlreadyActive
        );
        runtime.executor.shutdown().expect("executor shutdown");
    }

    #[test]
    fn platform_facts_compact_to_current_cellular_set_and_latest_vpn_snapshot() {
        let mut facts = ProductPlatformFacts::default();
        let handle_11 = NetworkHandle::new(11).expect("handle");
        let handle_12 = NetworkHandle::new(12).expect("handle");
        let sequence_1 = mish_cellular::ObservationSequence::new(1).expect("sequence");
        let sequence_2 = mish_cellular::ObservationSequence::new(2).expect("sequence");

        facts.record_cellular_observation(
            1,
            NetworkObservation::new(sequence_1, handle_11, true, true, true, true),
            handle_11,
            Some("rmnet0".to_owned()),
        );
        facts.record_cellular_observation(
            2,
            NetworkObservation::new(sequence_2, handle_12, true, true, true, true),
            handle_12,
            Some("rmnet1".to_owned()),
        );
        facts.record_cellular_loss(3, handle_12);
        facts.record_cellular_loss(2, handle_11);

        let replay = facts.cellular_replay();
        assert_eq!(replay.len(), 1);
        assert_eq!(replay[0].observed_handle, handle_11);
        assert_eq!(replay[0].sequence, 1);

        facts.record_cellular_loss(4, handle_11);
        assert!(facts.cellular_replay().is_empty());
        assert_eq!(facts.last_cellular_loss, Some((4, handle_11)));
        facts.clear_cellular();
        assert!(facts.cellular_replay().is_empty());
        assert_eq!(facts.last_cellular_loss, None);

        facts.record_mesh(5, MeshVpnObservation::Absent);
        facts.record_mesh(
            4,
            MeshVpnObservation::UniqueVpn {
                local_ipv4: vec![std::net::Ipv4Addr::new(100, 96, 2, 4)],
            },
        );
        let mesh = facts.mesh.expect("mesh fact");
        assert_eq!(mesh.sequence, 5);
        assert_eq!(mesh.observation, MeshVpnObservation::Absent);
        facts.clear_mesh();
        assert!(facts.mesh.is_none());
    }

    #[test]
    fn stopped_platform_mutation_lease_blocks_start_and_fail_closes_uncertain_effect() {
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");
        let lease = runtime
            .begin_stopped_platform_mutation()
            .expect("lease call")
            .expect("lease");

        assert_eq!(
            runtime.request_start(None, None, None),
            Err(RuntimeExecutionError::StateUnavailable),
        );
        assert!(!runtime
            .complete_stopped_platform_mutation(lease, false)
            .expect("complete"));
        assert!(runtime.snapshot().generation_requires_replacement);
        runtime.executor.shutdown().expect("executor shutdown");
    }

    #[test]
    fn successful_stopped_platform_mutation_advances_native_generation_once() {
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");
        let lease = runtime
            .begin_stopped_platform_mutation()
            .expect("lease call")
            .expect("lease");

        assert!(runtime
            .complete_stopped_platform_mutation(lease, true)
            .expect("complete"));
        let snapshot = runtime.snapshot();
        assert_eq!(snapshot.generation, 2);
        assert!(!snapshot.generation_requires_replacement);
        assert!(!runtime
            .complete_stopped_platform_mutation(lease, true)
            .expect("stale complete"));
        runtime.executor.shutdown().expect("executor shutdown");
    }
}
