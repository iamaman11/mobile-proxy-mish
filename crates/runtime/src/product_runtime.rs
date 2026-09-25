//! Stable PRODUCT process handle with Rust-owned runtime generation lifecycle.
//!
//! One process keeps one Tokio executor. Runtime generations are immutable composition aggregates
//! replaced inside this owner. Android may register platform observations against the stable handle;
//! it never constructs, numbers or replaces PRODUCT generations.

use crate::{
    CellularDnsResolver, CellularPolicyObserver, CellularRequestRearmEffect, ControlAuthSigner,
    ControlRuntimeSnapshot, ControlRuntimeStartError, MeshRuntimeObserver, ProductGeneration,
    ProxyRuntimeObserver, ReadinessObserver, RotationObserver, RuntimeExecutionError,
    RuntimeExecutor, RuntimeLifecycle, RuntimeLifecycleState, RuntimeStartAction,
    RuntimeStopAction,
};
use mish_cellular::{
    CellularAdmissionSnapshot, NetworkHandle, NetworkObservation, RootPolicyNamespace,
};
use mish_control::ControlDeviceIdentity;
use mish_transport::{MeshTransportError, MeshTransportSnapshot, MeshVpnObservation};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use tokio::task::spawn_blocking;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProductRuntimeSnapshot {
    pub state: RuntimeLifecycleState,
    pub generation: u64,
    pub generation_requires_replacement: bool,
    pub active_tasks: u64,
}

#[derive(Clone)]
struct ProductStartInput {
    credential_version: Option<u64>,
    username: Option<String>,
    password: Option<String>,
}

#[derive(Clone)]
struct ControlStartInput {
    public_key_spki: Vec<u8>,
    signer: Arc<dyn ControlAuthSigner>,
    cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
}

#[derive(Clone, Default)]
struct ProductObservers {
    cellular: Option<CellularPolicyObserver>,
    readiness: Option<ReadinessObserver>,
    proxy: Option<ProxyRuntimeObserver>,
    mesh: Option<MeshRuntimeObserver>,
    rotation: Option<RotationObserver>,
}

type ObserverRebind = (Arc<ProductGeneration>, ProductObservers);

struct ProductStopCompletion {
    rebind: Option<ObserverRebind>,
    restart: Option<ProductStartInput>,
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
    control_start: Option<ControlStartInput>,
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
                control_start: None,
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
                active_tasks: self.executor.active_task_count(),
            },
            |state| snapshot(&state, self.executor.active_task_count()),
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

    pub fn start_public_ip_rotation(
        self: &Arc<Self>,
        cellular_request_rearm: Arc<dyn crate::CellularRequestRearmEffect>,
    ) -> Result<u64, crate::RotationRuntimeStartError> {
        let generation = self
            .active_generation()
            .map_err(|_| crate::RotationRuntimeStartError::RuntimeNotRunning)?;
        generation.rotation().start(cellular_request_rearm)
    }

    pub fn rotation_snapshot(&self) -> mish_rotation::RotationSnapshot {
        self.current_generation()
            .map(|generation| generation.rotation().snapshot())
            .unwrap_or_else(|_| mish_rotation::RotationSnapshot::idle())
    }

    pub fn start_remote_control(
        self: &Arc<Self>,
        public_key_spki: Vec<u8>,
        signer: Arc<dyn ControlAuthSigner>,
        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
    ) -> Result<String, ControlRuntimeStartError> {
        let identity = ControlDeviceIdentity::from_public_key_spki(public_key_spki.clone())
            .map_err(|_| ControlRuntimeStartError::InvalidIdentity)?;
        let device_id = identity.device_id().to_owned();
        let input = ControlStartInput {
            public_key_spki,
            signer,
            cellular_request_rearm,
        };
        let (generation, previous, start_now) = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| ControlRuntimeStartError::StateUnavailable)?;
            let lifecycle = state.lifecycle.state();
            if state.closed
                || !matches!(
                    lifecycle,
                    RuntimeLifecycleState::Starting | RuntimeLifecycleState::Running
                )
            {
                return Err(ControlRuntimeStartError::StateUnavailable);
            }
            if state
                .control_start
                .as_ref()
                .is_some_and(|existing| existing.public_key_spki != input.public_key_spki)
            {
                return Err(ControlRuntimeStartError::AlreadyStarted);
            }
            let previous = state.control_start.replace(input.clone());
            (
                Arc::clone(&state.generation),
                previous,
                lifecycle == RuntimeLifecycleState::Running,
            )
        };

        // Remote control is ancillary to PRODUCT startup. While the lifecycle is STARTING, store
        // only the validated control intent. run_start() launches it after complete_start(), so
        // DNS/TCP/TLS/WebSocket work cannot compete with policy/proxy/readiness bootstrap.
        if !start_now {
            return Ok(device_id);
        }

        let result = generation.control().start(
            input.public_key_spki.clone(),
            Arc::clone(&input.signer),
            Arc::clone(&input.cellular_request_rearm),
        );
        if result.is_err()
            && let Ok(mut state) = self.state.lock()
        {
            state.control_start = previous;
        }
        result
    }

    pub fn control_snapshot(&self) -> ControlRuntimeSnapshot {
        self.current_generation()
            .map(|generation| generation.control().snapshot())
            .unwrap_or(ControlRuntimeSnapshot {
                state: crate::ControlSessionState::Stopped,
                reconnect_attempts: 0,
                reconnect_count: 0,
                next_delay_ms: 1_000,
                session_age_ms: None,
                application_heartbeat_count: 0,
                payload_tx_bytes: 0,
                payload_rx_bytes: 0,
                last_tx_age_ms: None,
                last_rx_age_ms: None,
                pending_operation: false,
                pending_operation_id: None,
                last_terminal_result: None,
                operation_timing: crate::ControlOperationTimingSnapshot::default(),
                rotation_timing: crate::RotationRuntimeTimingSnapshot::default(),
            })
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
            .rotation()
            .observe_platform_cellular_observation();
        let admission =
            generation
                .policy()
                .observe_network(observation, observed_handle, interface_name)?;
        generation.rotation().observe_cellular(admission);
        Ok(admission)
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
        let admission = generation
            .policy()
            .network_lost(sequence_value, observed_handle)?;
        generation.rotation().observe_cellular(admission);
        Ok(admission)
    }

    /// Forwards one transient typed Android radio POWER_OFF fact to the current Rust Rotation.
    ///
    /// This fact is deliberately not persisted in ProductPlatformFacts or replayed across runtime
    /// generation replacement. It is meaningful only to the single active Rotation operation.
    pub fn observe_radio_power_off(&self) -> Result<(), RuntimeExecutionError> {
        let generation = {
            let state = self.state()?;
            if !matches!(
                state.lifecycle.state(),
                RuntimeLifecycleState::Starting | RuntimeLifecycleState::Running
            ) {
                return Err(RuntimeExecutionError::StateUnavailable);
            }
            Arc::clone(&state.generation)
        };
        generation.rotation().observe_radio_power_off();
        Ok(())
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
        bind_cellular_observer(&generation, observer, Arc::clone(&self.observer_generation));
    }

    pub fn set_readiness_observer(&self, observer: ReadinessObserver) {
        let generation = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.observers.readiness = Some(Arc::clone(&observer));
            Arc::clone(&state.generation)
        };
        bind_readiness_observer(&generation, observer, Arc::clone(&self.observer_generation));
    }

    pub fn set_proxy_observer(&self, observer: ProxyRuntimeObserver) {
        let generation = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.observers.proxy = Some(Arc::clone(&observer));
            Arc::clone(&state.generation)
        };
        bind_proxy_observer(&generation, observer, Arc::clone(&self.observer_generation));
    }

    pub fn set_mesh_observer(&self, observer: MeshRuntimeObserver) {
        let generation = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.observers.mesh = Some(Arc::clone(&observer));
            Arc::clone(&state.generation)
        };
        bind_mesh_observer(&generation, observer, Arc::clone(&self.observer_generation));
    }

    pub fn set_rotation_observer(&self, observer: RotationObserver) {
        let generation = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.observers.rotation = Some(Arc::clone(&observer));
            Arc::clone(&state.generation)
        };
        bind_rotation_observer(&generation, observer, Arc::clone(&self.observer_generation));
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
    pub fn begin_stopped_platform_mutation(&self) -> Result<Option<u64>, RuntimeExecutionError> {
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
        bind_observers(&rebound.0, rebound.1, Arc::clone(&self.observer_generation));
        Ok(true)
    }

    pub fn request_stop(self: &Arc<Self>) -> Result<RuntimeStopAction, RuntimeExecutionError> {
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
            (Arc::clone(&state.generation), state.platform_facts.clone())
        };

        if generation.policy().start().is_err()
            || !replay_platform_facts(&generation, &platform_facts)
        {
            self.finish_failed_start(expected_generation, generation)
                .await;
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
            self.finish_failed_start(expected_generation, generation)
                .await;
            return;
        }

        let control_start = if let Ok(mut state) = self.state.lock()
            && !state.closed
            && state.lifecycle.generation() == expected_generation
            && state.lifecycle.state() == RuntimeLifecycleState::Starting
        {
            state.lifecycle.complete_start(true, true);
            state.control_start.clone()
        } else {
            None
        };

        if let Some(control) = control_start {
            let _ = generation.control().start(
                control.public_key_spki,
                control.signer,
                control.cellular_request_rearm,
            );
        }
    }

    async fn finish_failed_start(
        &self,
        expected_generation: u64,
        generation: Arc<ProductGeneration>,
    ) {
        let still_starting = {
            let Ok(state) = self.state.lock() else {
                return;
            };
            !state.closed
                && state.lifecycle.generation() == expected_generation
                && state.lifecycle.state() == RuntimeLifecycleState::Starting
                && Arc::ptr_eq(&state.generation, &generation)
        };
        if !still_starting {
            return;
        }

        // A concurrent stop may win after the check above. ProductGeneration shutdown is exact-once,
        // so both paths can safely await the same cleanup execution/result; only the lifecycle owner
        // whose state still matches is allowed to publish the terminal transition.
        let clean = generation.shutdown_async().await;
        if let Some((generation, observers)) =
            self.complete_failed_start_after_cleanup(expected_generation, clean)
        {
            bind_observers(
                &generation,
                observers,
                Arc::clone(&self.observer_generation),
            );
        }
    }

    fn complete_failed_start_after_cleanup(
        &self,
        expected_generation: u64,
        clean: bool,
    ) -> Option<ObserverRebind> {
        let Ok(mut state) = self.state.lock() else {
            return None;
        };
        if state.closed
            || state.lifecycle.generation() != expected_generation
            || state.lifecycle.state() != RuntimeLifecycleState::Starting
        {
            return None;
        }

        let completion = state.lifecycle.complete_start(false, clean);
        if !completion.install_fresh_generation_now() {
            return None;
        }

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
        let Some(completion) = self.complete_stop_after_cleanup(expected_generation, clean) else {
            return;
        };

        if let Some((generation, observers)) = completion.rebind {
            bind_observers(
                &generation,
                observers,
                Arc::clone(&self.observer_generation),
            );
        }

        if let Some(input) = completion.restart {
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

    fn complete_stop_after_cleanup(
        &self,
        expected_generation: u64,
        clean: bool,
    ) -> Option<ProductStopCompletion> {
        let Ok(mut state) = self.state.lock() else {
            return None;
        };
        if state.closed
            || state.lifecycle.generation() != expected_generation
            || state.lifecycle.state() != RuntimeLifecycleState::Stopping
        {
            return None;
        }

        let disposition = state.lifecycle.complete_stop(clean);
        let mut rebind = None;
        if disposition.install_fresh_generation_now() {
            match self.build_generation(state.lifecycle.generation()) {
                Ok(fresh) => {
                    state.generation = Arc::clone(&fresh);
                    self.observer_generation
                        .store(fresh.generation(), Ordering::Release);
                    rebind = Some((fresh, state.observers.clone()));
                }
                Err(_) => {
                    state.lifecycle.mark_stopped_generation_dirty();
                }
            }
        }

        let restart = if disposition.restart_now() && rebind.is_some() {
            state.pending_start.take()
        } else {
            state.pending_start = None;
            None
        };
        Some(ProductStopCompletion { rebind, restart })
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
    if cellular.is_empty()
        && let Some((sequence, handle)) = platform_facts.last_cellular_loss
    {
        let Some(sequence) = mish_cellular::ObservationSequence::new(sequence) else {
            return false;
        };
        if generation.policy().network_lost(sequence, handle).is_err() {
            return false;
        }
    }

    if let Some(mesh) = platform_facts.mesh.clone()
        && apply_mesh_observation(generation, mesh.sequence, mesh.observation).is_err()
    {
        return false;
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
        bind_proxy_observer(generation, observer, Arc::clone(&observer_generation));
    }
    if let Some(observer) = observers.mesh {
        bind_mesh_observer(generation, observer, Arc::clone(&observer_generation));
    }
    if let Some(observer) = observers.rotation {
        bind_rotation_observer(generation, observer, observer_generation);
    }
}

fn bind_cellular_observer(
    generation: &ProductGeneration,
    observer: CellularPolicyObserver,
    observer_generation: Arc<AtomicU64>,
) {
    let expected_generation = generation.generation();
    generation
        .policy()
        .set_observer(Arc::new(move |publication| {
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
    generation
        .readiness()
        .set_observer(Arc::new(move |readiness| {
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
    generation
        .proxy()
        .set_observer(Arc::new(move |publication| {
            if observer_generation.load(Ordering::Acquire) == expected_generation {
                observer(publication);
            }
        }));
}

fn bind_mesh_observer(
    generation: &ProductGeneration,
    observer: MeshRuntimeObserver,
    observer_generation: Arc<AtomicU64>,
) {
    let expected_generation = generation.generation();
    generation.mesh().set_observer(Arc::new(move |snapshot| {
        if observer_generation.load(Ordering::Acquire) == expected_generation {
            observer(snapshot);
        }
    }));
}

fn bind_rotation_observer(
    generation: &ProductGeneration,
    observer: RotationObserver,
    observer_generation: Arc<AtomicU64>,
) {
    let expected_generation = generation.generation();
    generation
        .rotation()
        .set_observer(Arc::new(move |snapshot| {
            if observer_generation.load(Ordering::Acquire) == expected_generation {
                observer(snapshot);
            }
        }));
}

fn snapshot(state: &ProductRuntimeState, active_tasks: u64) -> ProductRuntimeSnapshot {
    ProductRuntimeSnapshot {
        state: state.lifecycle.state(),
        generation: state.lifecycle.generation(),
        generation_requires_replacement: state.lifecycle.generation_requires_replacement(),
        active_tasks,
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

    struct TestControlSigner;

    impl ControlAuthSigner for TestControlSigner {
        fn sign_control_auth(
            &self,
            _payload: &[u8],
        ) -> Result<Vec<u8>, crate::ControlAuthSignError> {
            Ok(vec![1; 64])
        }
    }

    struct TestControlRearmEffect;

    impl CellularRequestRearmEffect for TestControlRearmEffect {
        fn rearm_cellular_request(&self) -> bool {
            true
        }
    }

    #[test]
    fn remote_control_is_deferred_until_product_start_completes() {
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_126,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");

        {
            let mut state = runtime.state_mut().expect("state");
            assert_eq!(
                state.lifecycle.request_start(),
                RuntimeStartAction::StartNow
            );
        }

        let device_id = runtime
            .start_remote_control(
                vec![1, 2, 3, 4],
                Arc::new(TestControlSigner),
                Arc::new(TestControlRearmEffect),
            )
            .expect("deferred control");

        assert_eq!(device_id.len(), 64);
        assert_eq!(
            runtime.control_snapshot().state,
            crate::ControlSessionState::Stopped
        );
        assert!(
            runtime
                .state()
                .expect("state")
                .control_start
                .as_ref()
                .is_some_and(|control| control.public_key_spki == vec![1, 2, 3, 4])
        );

        runtime.executor.shutdown().expect("executor shutdown");
    }

    #[test]
    fn starting_product_rejects_replacing_control_identity() {
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_127,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");

        {
            let mut state = runtime.state_mut().expect("state");
            assert_eq!(
                state.lifecycle.request_start(),
                RuntimeStartAction::StartNow
            );
        }

        runtime
            .start_remote_control(
                vec![1, 2, 3, 4],
                Arc::new(TestControlSigner),
                Arc::new(TestControlRearmEffect),
            )
            .expect("first control");
        assert_eq!(
            runtime.start_remote_control(
                vec![9, 8, 7, 6],
                Arc::new(TestControlSigner),
                Arc::new(TestControlRearmEffect),
            ),
            Err(ControlRuntimeStartError::AlreadyStarted)
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
        let mesh = facts.mesh.as_ref().expect("mesh fact");
        assert_eq!(mesh.sequence, 5);
        assert_eq!(mesh.observation, MeshVpnObservation::Absent);
        facts.clear_mesh();
        assert!(facts.mesh.is_none());
    }

    #[test]
    fn stop_supersedes_failed_start_completion_and_owns_terminal_transition() {
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");

        {
            let mut state = runtime.state_mut().expect("state");
            assert_eq!(
                state.lifecycle.request_start(),
                RuntimeStartAction::StartNow
            );
            assert_eq!(state.lifecycle.request_stop(), RuntimeStopAction::StopNow);
        }

        assert!(
            runtime
                .complete_failed_start_after_cleanup(1, true)
                .is_none()
        );
        assert_eq!(runtime.snapshot().state, RuntimeLifecycleState::Stopping);

        let completion = runtime
            .complete_stop_after_cleanup(1, true)
            .expect("stop completion");
        assert!(completion.restart.is_none());
        assert!(completion.rebind.is_some());
        let snapshot = runtime.snapshot();
        assert_eq!(snapshot.state, RuntimeLifecycleState::Stopped);
        assert_eq!(snapshot.generation, 2);
        assert!(!snapshot.generation_requires_replacement);
        runtime.executor.shutdown().expect("executor shutdown");
    }

    #[test]
    fn queued_restart_preserves_latest_platform_facts_for_fresh_generation() {
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");
        let handle = NetworkHandle::new(11).expect("handle");
        let sequence = mish_cellular::ObservationSequence::new(7).expect("sequence");

        {
            let mut state = runtime.state_mut().expect("state");
            state.platform_facts.record_cellular_observation(
                7,
                NetworkObservation::new(sequence, handle, true, true, true, true),
                handle,
                Some("rmnet0".to_owned()),
            );
            state
                .platform_facts
                .record_mesh(9, MeshVpnObservation::Absent);
            assert_eq!(
                state.lifecycle.request_start(),
                RuntimeStartAction::StartNow
            );
            state.lifecycle.complete_start(true, true);
            assert_eq!(state.lifecycle.request_stop(), RuntimeStopAction::StopNow);
        }

        assert_eq!(
            runtime
                .request_start(
                    Some(4),
                    Some("queued-user".to_owned()),
                    Some("queued-password".to_owned()),
                )
                .expect("queued start"),
            RuntimeStartAction::QueuedAfterStop
        );

        let completion = runtime
            .complete_stop_after_cleanup(1, true)
            .expect("stop completion");
        let restart = completion.restart.expect("queued restart");
        assert_eq!(restart.credential_version, Some(4));
        assert_eq!(restart.username.as_deref(), Some("queued-user"));
        assert_eq!(restart.password.as_deref(), Some("queued-password"));
        assert!(completion.rebind.is_some());

        let state = runtime.state().expect("state");
        assert_eq!(state.lifecycle.generation(), 2);
        let replay = state.platform_facts.cellular_replay();
        assert_eq!(replay.len(), 1);
        assert_eq!(replay[0].sequence, 7);
        assert_eq!(
            state.platform_facts.mesh.as_ref().map(|mesh| mesh.sequence),
            Some(9)
        );
        drop(state);
        runtime.executor.shutdown().expect("executor shutdown");
    }

    #[test]
    fn newer_explicit_stop_while_stopping_cancels_queued_restart() {
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");

        {
            let mut state = runtime.state_mut().expect("state");
            assert_eq!(
                state.lifecycle.request_start(),
                RuntimeStartAction::StartNow
            );
            state.lifecycle.complete_start(true, true);
            assert_eq!(state.lifecycle.request_stop(), RuntimeStopAction::StopNow);
        }

        assert_eq!(
            runtime
                .request_start(
                    Some(3),
                    Some("queued-user".to_owned()),
                    Some("queued-password".to_owned()),
                )
                .expect("queued start"),
            RuntimeStartAction::QueuedAfterStop
        );
        assert_eq!(
            runtime.request_stop().expect("newer stop"),
            RuntimeStopAction::AlreadyStopping
        );

        let completion = runtime
            .complete_stop_after_cleanup(1, true)
            .expect("stop completion");
        assert!(completion.restart.is_none());
        assert_eq!(runtime.snapshot().state, RuntimeLifecycleState::Stopped);
        runtime.executor.shutdown().expect("executor shutdown");
    }

    #[test]
    fn stale_generation_proxy_publication_is_fenced_from_android_observer() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");
        let publications = Arc::new(AtomicUsize::new(0));
        let observed = Arc::clone(&publications);
        runtime.set_proxy_observer(Arc::new(move |_| {
            observed.fetch_add(1, Ordering::SeqCst);
        }));
        let baseline = publications.load(Ordering::SeqCst);
        let old_generation = runtime.current_generation().expect("generation");

        runtime.observer_generation.store(2, Ordering::Release);
        let _ = old_generation.proxy().start(None, None, None);

        assert_eq!(publications.load(Ordering::SeqCst), baseline);
        runtime.executor.shutdown().expect("executor shutdown");
    }

    #[test]
    fn mesh_publication_is_owner_driven_and_generation_fenced() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");
        let publications = Arc::new(AtomicUsize::new(0));
        let observed = Arc::clone(&publications);
        runtime.set_mesh_observer(Arc::new(move |_| {
            observed.fetch_add(1, Ordering::SeqCst);
        }));
        let baseline = publications.load(Ordering::SeqCst);
        let generation = runtime.current_generation().expect("generation");

        generation
            .mesh()
            .set_readiness_ready(true)
            .expect("readiness reconcile");
        assert_eq!(publications.load(Ordering::SeqCst), baseline + 1);

        runtime.observer_generation.store(2, Ordering::Release);
        generation
            .mesh()
            .set_readiness_ready(false)
            .expect("stale readiness reconcile");
        assert_eq!(publications.load(Ordering::SeqCst), baseline + 1);
        runtime.executor.shutdown().expect("executor shutdown");
    }

    #[test]
    fn failed_start_cleanup_result_controls_exact_generation_replacement() {
        let clean = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("clean runtime");
        {
            let mut state = clean.state_mut().expect("state");
            assert_eq!(
                state.lifecycle.request_start(),
                RuntimeStartAction::StartNow
            );
        }
        assert!(clean.complete_failed_start_after_cleanup(1, true).is_some());
        let clean_snapshot = clean.snapshot();
        assert_eq!(clean_snapshot.state, RuntimeLifecycleState::Stopped);
        assert_eq!(clean_snapshot.generation, 2);
        assert!(!clean_snapshot.generation_requires_replacement);
        clean.executor.shutdown().expect("clean executor shutdown");

        let dirty = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_124,
            RootPolicyNamespace::Debug,
        )
        .expect("dirty runtime");
        {
            let mut state = dirty.state_mut().expect("state");
            assert_eq!(
                state.lifecycle.request_start(),
                RuntimeStartAction::StartNow
            );
        }
        assert!(
            dirty
                .complete_failed_start_after_cleanup(1, false)
                .is_none()
        );
        let dirty_snapshot = dirty.snapshot();
        assert_eq!(dirty_snapshot.state, RuntimeLifecycleState::Stopped);
        assert_eq!(dirty_snapshot.generation, 1);
        assert!(dirty_snapshot.generation_requires_replacement);
        dirty.executor.shutdown().expect("dirty executor shutdown");
    }

    #[test]
    fn final_process_close_blocks_late_generation_completion() {
        let starting = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("starting runtime");
        {
            let mut state = starting.state_mut().expect("state");
            assert_eq!(
                state.lifecycle.request_start(),
                RuntimeStartAction::StartNow
            );
            state.closed = true;
        }
        assert!(
            starting
                .complete_failed_start_after_cleanup(1, true)
                .is_none()
        );
        assert_eq!(starting.snapshot().generation, 1);
        starting
            .executor
            .shutdown()
            .expect("starting executor shutdown");

        let stopping = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_124,
            RootPolicyNamespace::Debug,
        )
        .expect("stopping runtime");
        {
            let mut state = stopping.state_mut().expect("state");
            assert_eq!(
                state.lifecycle.request_start(),
                RuntimeStartAction::StartNow
            );
            state.lifecycle.complete_start(true, true);
            assert_eq!(state.lifecycle.request_stop(), RuntimeStopAction::StopNow);
            state.closed = true;
        }
        assert!(stopping.complete_stop_after_cleanup(1, true).is_none());
        assert_eq!(stopping.snapshot().generation, 1);
        stopping
            .executor
            .shutdown()
            .expect("stopping executor shutdown");
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
        assert!(
            !runtime
                .complete_stopped_platform_mutation(lease, false)
                .expect("complete")
        );
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

        assert!(
            runtime
                .complete_stopped_platform_mutation(lease, true)
                .expect("complete")
        );
        let snapshot = runtime.snapshot();
        assert_eq!(snapshot.generation, 2);
        assert!(!snapshot.generation_requires_replacement);
        assert!(
            !runtime
                .complete_stopped_platform_mutation(lease, true)
                .expect("stale complete")
        );
        runtime.executor.shutdown().expect("executor shutdown");
    }
}
