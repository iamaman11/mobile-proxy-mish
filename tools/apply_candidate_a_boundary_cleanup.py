#!/usr/bin/env python3
"""One-shot asserted removal of airplane/rearm compatibility seams for #450.

The consumer workflow deletes this script before committing. Every structural rewrite is checked so
source drift fails closed instead of leaving a mixed Candidate-A/airplane boundary.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    target = ROOT / path
    if not target.is_file():
        raise SystemExit(f"missing required file: {path}")
    return target.read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    (ROOT / path).write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def replace_count(text: str, old: str, new: str, expected: int, label: str) -> str:
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{label}: expected {expected} matches, found {count}")
    return text.replace(old, new)


def regex_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one regex match, found {count}")
    return updated


def cleanup_rotation_domain() -> None:
    path = "crates/rotation/src/lib.rs"
    text = read(path)
    text = replace_once(
        text,
        '''\n    // Transitional source-compatibility aliases for the Android projection. They are not active\n    // state-machine vocabulary and can be removed when the generated boundary is regenerated.\n    #[allow(non_upper_case_globals)]\n    pub const AirplaneEnabling: Self = Self::DataDisabling;\n    #[allow(non_upper_case_globals)]\n    pub const WaitingRadioDown: Self = Self::WaitingCellularLoss;\n    #[allow(non_upper_case_globals)]\n    pub const AirplaneDisabling: Self = Self::DataEnabling;\n''',
        "",
        "remove phase aliases",
    )
    text = regex_once(
        text,
        r'''\nimpl RotationFailure \{\n    // Transitional source-compatibility aliases for the Android projection only\.\n.*?\n\}\n''',
        "\n",
        "remove failure aliases",
    )
    text = regex_once(
        text,
        r'''\nimpl RotationRestoreResult \{\n    // Transitional source-compatibility aliases for the Android projection only\.\n.*?\n\}\n''',
        "\n",
        "remove restore aliases",
    )
    for obsolete in (
        "AirplaneEnabling",
        "WaitingRadioDown",
        "AirplaneDisabling",
        "AirplaneEnableFailed",
        "AirplaneObservationFailed",
        "AirplaneDisableFailed",
        "AlreadyOff",
        "RestoredOff",
    ):
        if obsolete in text:
            raise SystemExit(f"rotation domain still contains obsolete alias {obsolete}")
    write(path, text)


def cleanup_rotation_runtime() -> None:
    path = "crates/runtime/src/rotation_runtime.rs"
    text = read(path)
    text = regex_once(
        text,
        r'''\n/// Compatibility-only Android boundary retained during the Candidate A transition\..*?pub trait CellularRequestRearmEffect: Send \+ Sync \+ 'static \{\n    fn rearm_cellular_request\(&self\) -> bool;\n\}\n''',
        "\n",
        "remove rearm trait",
    )
    text = replace_once(
        text,
        '''/// These values never drive state transitions, retries or deadlines. The airplane/rearm fields are\n/// compatibility projection slots and remain empty for Candidate A until the generated boundary is\n/// cleaned up; the mobile-data fields are the new authoritative timing map.\n''',
        '''/// These values never drive state transitions, retries or deadlines. Every field describes the\n/// active Candidate A mobile-data detach/attach path or its generation-bound recovery proof.\n''',
        "timing documentation",
    )
    for field in (
        "    pub airplane_enable_started_ms: Option<u64>,\n",
        "    pub airplane_enable_effect_completed_ms: Option<u64>,\n",
        "    pub airplane_on_observed_ms: Option<u64>,\n",
        "    pub radio_power_off_observed_ms: Option<u64>,\n",
        "    pub airplane_disable_started_ms: Option<u64>,\n",
        "    pub airplane_disable_effect_completed_ms: Option<u64>,\n",
        "    pub airplane_off_observed_ms: Option<u64>,\n",
        "    pub cellular_request_rearm_started_ms: Option<u64>,\n",
        "    pub cellular_request_rearm_completed_ms: Option<u64>,\n",
        "    pub first_platform_cellular_observation_ms: Option<u64>,\n",
        "    pub platform_cellular_observations_after_rearm: u64,\n",
    ):
        text = replace_once(text, field, "", f"remove timing field {field.strip()}")

    text = regex_once(
        text,
        r'''    pub fn start\(\n        self: &Arc<Self>,\n        _compat_rearm: Arc<dyn CellularRequestRearmEffect>,\n    \) -> Result<u64, RotationRuntimeStartError> \{\n        let operation_id = self\.prepare\(_compat_rearm\)\?;''',
        '''    pub fn start(self: &Arc<Self>) -> Result<u64, RotationRuntimeStartError> {\n        let operation_id = self.prepare()?;''',
        "direct rotation start",
    )
    text = regex_once(
        text,
        r'''    pub fn prepare\(\n        self: &Arc<Self>,\n        _compat_rearm: Arc<dyn CellularRequestRearmEffect>,\n    \) -> Result<u64, RotationRuntimeStartError> \{''',
        '''    pub fn prepare(self: &Arc<Self>) -> Result<u64, RotationRuntimeStartError> {''',
        "direct rotation prepare",
    )
    text = regex_once(
        text,
        r'''\n    /// Compatibility no-op\. Candidate A relies on the already-running Android Cellular observer;\n    /// it never re-arms or owns that request\.\n    pub\(crate\) fn observe_platform_cellular_observation\(&self\) \{\}\n''',
        "\n",
        "remove platform-observation no-op",
    )
    text = regex_once(
        text,
        r'''\n    /// Compatibility no-op for the old airplane-specific Android telephony observer\.\n    pub fn observe_radio_power_off\(self: &Arc<Self>\) \{\}\n''',
        "\n",
        "remove radio-power no-op",
    )
    for obsolete in (
        "CellularRequestRearmEffect",
        "_compat_rearm",
        "observe_platform_cellular_observation",
        "observe_radio_power_off",
        "airplane_enable_",
        "airplane_on_observed",
        "radio_power_off_observed",
        "airplane_disable_",
        "airplane_off_observed",
        "cellular_request_rearm_",
        "platform_cellular_observations_after_rearm",
    ):
        if obsolete in text:
            raise SystemExit(f"rotation runtime still contains obsolete seam {obsolete}")
    write(path, text)


def cleanup_control_runtime() -> None:
    path = "crates/runtime/src/control_runtime.rs"
    text = read(path)
    text = replace_once(
        text,
        '''use crate::{\n    CellularRequestRearmEffect, MeshCompositionCoordinator, ProxyRuntimeCoordinator,\n    ReadinessRuntimeCoordinator, RotationRuntimeCoordinator, RotationRuntimeStartError,\n''',
        '''use crate::{\n    MeshCompositionCoordinator, ProxyRuntimeCoordinator, ReadinessRuntimeCoordinator,\n    RotationRuntimeCoordinator, RotationRuntimeStartError,\n''',
        "remove control rearm import",
    )
    text = replace_count(
        text,
        "        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,\n",
        "",
        5,
        "remove control rearm parameters",
    )
    text = replace_once(
        text,
        '''                owner\n                    .run_loop(identity, signer, cellular_request_rearm, cancel_rx)\n                    .await;\n''',
        '''                owner.run_loop(identity, signer, cancel_rx).await;\n''',
        "control run loop call",
    )
    text = replace_once(
        text,
        '''                .connect_and_run(\n                    &identity,\n                    Arc::clone(&signer),\n                    Arc::clone(&cellular_request_rearm),\n                    &mut cancel,\n                )\n''',
        '''                .connect_and_run(&identity, Arc::clone(&signer), &mut cancel)\n''',
        "control connect call",
    )
    text = replace_once(
        text,
        '''                            self.handle_server_message(\n                                &mut transport,\n                                &text,\n                                Arc::clone(&cellular_request_rearm),\n                            ).await?;\n''',
        '''                            self.handle_server_message(&mut transport, &text).await?;\n''',
        "control message call",
    )
    text = replace_once(
        text,
        '''            ServerControlMessage::RotateIp { request_id } => {\n                self.handle_rotate_ip(transport, request_id, cellular_request_rearm)\n                    .await\n            }\n''',
        '''            ServerControlMessage::RotateIp { request_id } => {\n                self.handle_rotate_ip(transport, request_id).await\n            }\n''',
        "control rotate dispatch",
    )
    text = replace_once(
        text,
        "        let operation_id = match self.rotation.prepare(Arc::clone(&cellular_request_rearm)) {\n",
        "        let operation_id = match self.rotation.prepare() {\n",
        "control direct prepare",
    )
    text = text.replace("intentional radio outage", "intentional Cellular detach")
    if "CellularRequestRearmEffect" in text or "cellular_request_rearm" in text:
        raise SystemExit("control runtime still transports a rearm effect")
    write(path, text)


def cleanup_product_runtime() -> None:
    path = "crates/runtime/src/product_runtime.rs"
    text = read(path)
    text = replace_once(
        text,
        '''use crate::{\n    CellularDnsResolver, CellularPolicyObserver, CellularRequestRearmEffect, ControlAuthSigner,\n''',
        '''use crate::{\n    CellularDnsResolver, CellularPolicyObserver, ControlAuthSigner,\n''',
        "remove product rearm import",
    )
    text = replace_once(
        text,
        '''struct ControlStartInput {\n    public_key_spki: Vec<u8>,\n    signer: Arc<dyn ControlAuthSigner>,\n    cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,\n}\n''',
        '''struct ControlStartInput {\n    public_key_spki: Vec<u8>,\n    signer: Arc<dyn ControlAuthSigner>,\n}\n''',
        "control start input",
    )
    text = regex_once(
        text,
        r'''    pub fn start_public_ip_rotation\(\n        self: &Arc<Self>,\n        cellular_request_rearm: Arc<dyn crate::CellularRequestRearmEffect>,\n    \) -> Result<u64, crate::RotationRuntimeStartError> \{\n        let generation = self\n            \.active_generation\(\)\n            \.map_err\(\|_\| crate::RotationRuntimeStartError::RuntimeNotRunning\)\?;\n        generation\.rotation\(\)\.start\(cellular_request_rearm\)\n    \}''',
        '''    pub fn start_public_ip_rotation(\n        self: &Arc<Self>,\n    ) -> Result<u64, crate::RotationRuntimeStartError> {\n        let generation = self\n            .active_generation()\n            .map_err(|_| crate::RotationRuntimeStartError::RuntimeNotRunning)?;\n        generation.rotation().start()\n    }''',
        "product direct rotation start",
    )
    text = replace_once(
        text,
        "        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,\n",
        "",
        "product remote control parameter",
    )
    text = replace_once(
        text,
        '''        let input = ControlStartInput {\n            public_key_spki,\n            signer,\n            cellular_request_rearm,\n        };\n''',
        '''        let input = ControlStartInput {\n            public_key_spki,\n            signer,\n        };\n''',
        "product control input construction",
    )
    text = replace_once(
        text,
        '''        let result = generation.control().start(\n            input.public_key_spki.clone(),\n            Arc::clone(&input.signer),\n            Arc::clone(&input.cellular_request_rearm),\n        );\n''',
        '''        let result = generation\n            .control()\n            .start(input.public_key_spki.clone(), Arc::clone(&input.signer));\n''',
        "product immediate control start",
    )
    text = replace_once(
        text,
        '''        generation\n            .rotation()\n            .observe_platform_cellular_observation();\n''',
        "",
        "remove product rotation callback attribution",
    )
    text = regex_once(
        text,
        r'''\n    /// Forwards one transient typed Android radio POWER_OFF fact to the current Rust Rotation\..*?\n    pub fn observe_radio_power_off\(&self\) -> Result<\(\), RuntimeExecutionError> \{.*?\n    \}\n\n    pub fn observe_mesh_vpn''',
        "\n    pub fn observe_mesh_vpn",
        "remove product POWER_OFF seam",
    )
    # Stored CONTROL intent is replayed after startup/generation replacement. Remove the obsolete
    # third argument from that native-to-native start as well.
    text = text.replace(
        '''generation.control().start(\n                    control.public_key_spki.clone(),\n                    Arc::clone(&control.signer),\n                    Arc::clone(&control.cellular_request_rearm),\n                )''',
        '''generation\n                .control()\n                .start(control.public_key_spki.clone(), Arc::clone(&control.signer))''',
    )
    if "CellularRequestRearmEffect" in text or "cellular_request_rearm" in text:
        raise SystemExit("product runtime still contains rearm compatibility state")
    if "observe_radio_power_off" in text or "observe_platform_cellular_observation" in text:
        raise SystemExit("product runtime still contains airplane/rearm callback seam")
    write(path, text)


def cleanup_ffi() -> None:
    path = "crates/android-ffi/src/product_runtime_ffi.rs"
    text = read(path)
    text = replace_once(
        text,
        '''    CellularPolicyObserver, CellularPolicyPublication, CellularReconcileDiagnostic,\n    CellularRequestRearmEffect, ControlAuthSignError, ControlAuthSigner,\n''',
        '''    CellularPolicyObserver, CellularPolicyPublication, CellularReconcileDiagnostic,\n    ControlAuthSignError, ControlAuthSigner,\n''',
        "remove ffi rearm import",
    )
    text = replace_once(
        text,
        '''pub enum RotationPhaseView {\n    Idle,\n    Preparing,\n    AirplaneEnabling,\n    WaitingRadioDown,\n    AirplaneDisabling,\n''',
        '''pub enum RotationPhaseView {\n    Idle,\n    Preparing,\n    DataDisabling,\n    WaitingCellularLoss,\n    DataEnabling,\n''',
        "ffi rotation phases",
    )
    text = replace_once(
        text,
        '''    BeforeIpFailed,\n    AirplaneEnableFailed,\n    AirplaneObservationFailed,\n    AirplaneDisableFailed,\n''',
        '''    BeforeIpFailed,\n    DataDisableFailed,\n    MobileDataObservationFailed,\n    DataEnableFailed,\n''',
        "ffi rotation failures",
    )
    text = replace_once(
        text,
        '''pub enum RotationRestoreResultView {\n    NotRequired,\n    AlreadyOff,\n    RestoredOff,\n''',
        '''pub enum RotationRestoreResultView {\n    NotRequired,\n    AlreadyEnabled,\n    RestoredEnabled,\n''',
        "ffi restore results",
    )
    old_timing = '''pub struct RotationRuntimeTimingView {\n    pub operation_id: Option<u64>,\n    pub operation_age_ms: Option<u64>,\n    pub activated_ms: Option<u64>,\n    pub pre_rotation_probe_started_ms: Option<u64>,\n    pub pre_rotation_probe_completed_ms: Option<u64>,\n    pub airplane_enable_started_ms: Option<u64>,\n    pub airplane_enable_effect_completed_ms: Option<u64>,\n    pub airplane_on_observed_ms: Option<u64>,\n    pub cellular_loss_observed_ms: Option<u64>,\n    pub radio_power_off_observed_ms: Option<u64>,\n    pub airplane_disable_started_ms: Option<u64>,\n    pub airplane_disable_effect_completed_ms: Option<u64>,\n    pub airplane_off_observed_ms: Option<u64>,\n    pub cellular_request_rearm_started_ms: Option<u64>,\n    pub cellular_request_rearm_completed_ms: Option<u64>,\n    pub first_platform_cellular_observation_ms: Option<u64>,\n    pub platform_cellular_observations_after_rearm: u64,\n    pub fresh_cellular_observed_ms: Option<u64>,\n'''
    new_timing = '''pub struct RotationRuntimeTimingView {\n    pub operation_id: Option<u64>,\n    pub operation_age_ms: Option<u64>,\n    pub activated_ms: Option<u64>,\n    pub pre_rotation_probe_started_ms: Option<u64>,\n    pub pre_rotation_probe_completed_ms: Option<u64>,\n    pub mobile_data_precondition_observed_ms: Option<u64>,\n    pub mobile_data_precondition_enabled: Option<bool>,\n    pub data_disable_started_ms: Option<u64>,\n    pub data_disable_effect_completed_ms: Option<u64>,\n    pub cellular_loss_observed_ms: Option<u64>,\n    pub data_enable_started_ms: Option<u64>,\n    pub data_enable_effect_completed_ms: Option<u64>,\n    pub fresh_cellular_observed_ms: Option<u64>,\n'''
    text = replace_once(text, old_timing, new_timing, "ffi timing record")
    text = regex_once(
        text,
        r'''\n#\[uniffi::export\(foreign\)\]\npub trait NativeCellularRequestRearmEffect: Send \+ Sync \{\n    fn rearm_cellular_request\(&self\) -> bool;\n\}\n''',
        "\n",
        "remove foreign rearm trait",
    )
    text = regex_once(
        text,
        r'''\nstruct ForeignCellularRequestRearmEffect \{.*?\n\}\n\nimpl CellularRequestRearmEffect for ForeignCellularRequestRearmEffect \{.*?\n\}\n''',
        "\n",
        "remove foreign rearm adapter",
    )
    text = regex_once(
        text,
        r'''    pub fn start_public_ip_rotation\(\n        self: &Arc<Self>,\n        cellular_request_rearm: Arc<dyn NativeCellularRequestRearmEffect>,\n    \) -> Result<u64, NativeRotationStartError> \{\n        self\.runtime\n            \.start_public_ip_rotation\(Arc::new\(ForeignCellularRequestRearmEffect \{\n                effect: cellular_request_rearm,\n            \}\)\)\n            \.map_err\(Into::into\)\n    \}''',
        '''    pub fn start_public_ip_rotation(\n        self: &Arc<Self>,\n    ) -> Result<u64, NativeRotationStartError> {\n        self.runtime.start_public_ip_rotation().map_err(Into::into)\n    }''',
        "ffi direct rotation start",
    )
    text = regex_once(
        text,
        r'''    pub fn start_remote_control\(\n        self: &Arc<Self>,\n        public_key_spki: Vec<u8>,\n        signer: Arc<dyn NativeControlAuthSigner>,\n        cellular_request_rearm: Arc<dyn NativeCellularRequestRearmEffect>,\n    \) -> Result<String, NativeControlStartError> \{\n        self\.runtime\n            \.start_remote_control\(\n                public_key_spki,\n                Arc::new\(ForeignControlAuthSigner \{ signer \}\),\n                Arc::new\(ForeignCellularRequestRearmEffect \{\n                    effect: cellular_request_rearm,\n                \}\),\n            \)\n            \.map_err\(Into::into\)\n    \}''',
        '''    pub fn start_remote_control(\n        self: &Arc<Self>,\n        public_key_spki: Vec<u8>,\n        signer: Arc<dyn NativeControlAuthSigner>,\n    ) -> Result<String, NativeControlStartError> {\n        self.runtime\n            .start_remote_control(public_key_spki, Arc::new(ForeignControlAuthSigner { signer }))\n            .map_err(Into::into)\n    }''',
        "ffi direct control start",
    )
    text = regex_once(
        text,
        r'''\n    /// Positive Android telephony fact only\. Rust decides whether it belongs to an active\n    /// Rotation and whether the radio-down gate is complete\.\n    pub fn observe_radio_power_off\(&self\) -> Result<\(\), NativeProductRuntimeError> \{\n        self\.runtime\.observe_radio_power_off\(\)\.map_err\(Into::into\)\n    \}\n''',
        "\n",
        "remove ffi POWER_OFF export",
    )
    old_map_timing = '''        pre_rotation_probe_started_ms: timing.pre_rotation_probe_started_ms,\n        pre_rotation_probe_completed_ms: timing.pre_rotation_probe_completed_ms,\n        airplane_enable_started_ms: timing.airplane_enable_started_ms,\n        airplane_enable_effect_completed_ms: timing.airplane_enable_effect_completed_ms,\n        airplane_on_observed_ms: timing.airplane_on_observed_ms,\n        cellular_loss_observed_ms: timing.cellular_loss_observed_ms,\n        radio_power_off_observed_ms: timing.radio_power_off_observed_ms,\n        airplane_disable_started_ms: timing.airplane_disable_started_ms,\n        airplane_disable_effect_completed_ms: timing.airplane_disable_effect_completed_ms,\n        airplane_off_observed_ms: timing.airplane_off_observed_ms,\n        cellular_request_rearm_started_ms: timing.cellular_request_rearm_started_ms,\n        cellular_request_rearm_completed_ms: timing.cellular_request_rearm_completed_ms,\n        first_platform_cellular_observation_ms: timing.first_platform_cellular_observation_ms,\n        platform_cellular_observations_after_rearm: timing\n            .platform_cellular_observations_after_rearm,\n'''
    new_map_timing = '''        pre_rotation_probe_started_ms: timing.pre_rotation_probe_started_ms,\n        pre_rotation_probe_completed_ms: timing.pre_rotation_probe_completed_ms,\n        mobile_data_precondition_observed_ms: timing.mobile_data_precondition_observed_ms,\n        mobile_data_precondition_enabled: timing.mobile_data_precondition_enabled,\n        data_disable_started_ms: timing.data_disable_started_ms,\n        data_disable_effect_completed_ms: timing.data_disable_effect_completed_ms,\n        cellular_loss_observed_ms: timing.cellular_loss_observed_ms,\n        data_enable_started_ms: timing.data_enable_started_ms,\n        data_enable_effect_completed_ms: timing.data_enable_effect_completed_ms,\n'''
    text = replace_once(text, old_map_timing, new_map_timing, "ffi timing mapping")

    replacements = {
        "RotationPhase::AirplaneEnabling => RotationPhaseView::AirplaneEnabling": "RotationPhase::DataDisabling => RotationPhaseView::DataDisabling",
        "RotationPhase::WaitingRadioDown => RotationPhaseView::WaitingRadioDown": "RotationPhase::WaitingCellularLoss => RotationPhaseView::WaitingCellularLoss",
        "RotationPhase::AirplaneDisabling => RotationPhaseView::AirplaneDisabling": "RotationPhase::DataEnabling => RotationPhaseView::DataEnabling",
        "RotationFailure::AirplaneEnableFailed => RotationFailureView::AirplaneEnableFailed": "RotationFailure::DataDisableFailed => RotationFailureView::DataDisableFailed",
        "RotationFailure::AirplaneObservationFailed => {\n            RotationFailureView::AirplaneObservationFailed\n        }": "RotationFailure::MobileDataObservationFailed => {\n            RotationFailureView::MobileDataObservationFailed\n        }",
        "RotationFailure::AirplaneDisableFailed => RotationFailureView::AirplaneDisableFailed": "RotationFailure::DataEnableFailed => RotationFailureView::DataEnableFailed",
        "RotationRestoreResult::AlreadyOff => RotationRestoreResultView::AlreadyOff": "RotationRestoreResult::AlreadyEnabled => RotationRestoreResultView::AlreadyEnabled",
        "RotationRestoreResult::RestoredOff => RotationRestoreResultView::RestoredOff": "RotationRestoreResult::RestoredEnabled => RotationRestoreResultView::RestoredEnabled",
        "RotationPhase::AirplaneEnabling => \"AIRPLANE_ENABLING\"": "RotationPhase::DataDisabling => \"DATA_DISABLING\"",
        "RotationPhase::WaitingRadioDown => \"WAITING_RADIO_DOWN\"": "RotationPhase::WaitingCellularLoss => \"WAITING_CELLULAR_LOSS\"",
        "RotationPhase::AirplaneDisabling => \"AIRPLANE_DISABLING\"": "RotationPhase::DataEnabling => \"DATA_ENABLING\"",
        "RotationFailure::AirplaneEnableFailed => \"AIRPLANE_ENABLE_FAILED\"": "RotationFailure::DataDisableFailed => \"DATA_DISABLE_FAILED\"",
        "RotationFailure::AirplaneObservationFailed => \"AIRPLANE_OBSERVATION_FAILED\"": "RotationFailure::MobileDataObservationFailed => \"MOBILE_DATA_OBSERVATION_FAILED\"",
        "RotationFailure::AirplaneDisableFailed => \"AIRPLANE_DISABLE_FAILED\"": "RotationFailure::DataEnableFailed => \"DATA_ENABLE_FAILED\"",
        "RotationRestoreResult::AlreadyOff => \"ALREADY_OFF\"": "RotationRestoreResult::AlreadyEnabled => \"ALREADY_ENABLED\"",
        "RotationRestoreResult::RestoredOff => \"RESTORED_OFF\"": "RotationRestoreResult::RestoredEnabled => \"RESTORED_ENABLED\"",
    }
    for old, new in replacements.items():
        text = replace_once(text, old, new, f"ffi mapping {old}")

    for obsolete in (
        "NativeCellularRequestRearmEffect",
        "ForeignCellularRequestRearmEffect",
        "CellularRequestRearmEffect",
        "cellular_request_rearm",
        "observe_radio_power_off",
        "AirplaneEnabling",
        "WaitingRadioDown",
        "AirplaneDisabling",
        "AirplaneEnableFailed",
        "AirplaneObservationFailed",
        "AirplaneDisableFailed",
        "AlreadyOff",
        "RestoredOff",
        "airplane_enable_",
        "airplane_on_observed",
        "radio_power_off_observed",
        "airplane_disable_",
        "airplane_off_observed",
        "cellular_request_rearm_",
        "platform_cellular_observations_after_rearm",
    ):
        if obsolete in text:
            raise SystemExit(f"FFI still contains obsolete seam {obsolete}")
    write(path, text)


def cleanup_kotlin() -> None:
    controller = "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt"
    text = read(controller)
    text = replace_once(
        text,
        "import com.mobileproxymish.ffi.NativeCellularRequestRearmEffect\n",
        "",
        "controller rearm import",
    )
    text = regex_once(
        text,
        r'''    private val cellularRequestRearmEffect = object : NativeCellularRequestRearmEffect \{\n        override fun rearmCellularRequest\(\): Boolean = cellularRuntime\.rearmNetworkRequest\(\)\n    \}\n''',
        "",
        "controller rearm object",
    )
    text = replace_once(
        text,
        "        productRuntime.startPublicIpRotation(cellularRequestRearmEffect)\n",
        "        productRuntime.startPublicIpRotation()\n",
        "controller direct rotate",
    )
    text = replace_once(
        text,
        '''            productRuntime.startRemoteControl(\n                spki,\n                controlAuthSigner,\n                cellularRequestRearmEffect,\n            )\n''',
        '''            productRuntime.startRemoteControl(spki, controlAuthSigner)\n''',
        "controller direct control",
    )
    if "Rearm" in text or "rearm" in text:
        raise SystemExit("MishRuntimeController still contains rearm compatibility code")
    write(controller, text)

    bridge = "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt"
    text = read(bridge)
    text = regex_once(
        text,
        r'''    private val radioPowerObserver = CellularRadioPowerObserver\(context\) \{\n        // A callback outside a live Rotation is intentionally a no-op in Rust\.\n        runCatching \{ productRuntime\.observeRadioPowerOff\(\) \}\n    \}\n''',
        "",
        "bridge radio observer",
    )
    text = regex_once(
        text,
        r'''\n    /\*\* Android framework effect only; Rust owns if/when a rotation requests this once\. \*/\n    internal fun rearmNetworkRequest\(\): Boolean \{.*?\n    \}\n''',
        "\n",
        "bridge rearm method",
    )
    text = replace_once(text, "            radioPowerObserver.start()\n", "", "bridge radio start")
    text = replace_once(text, "                radioPowerObserver.close()\n", "", "bridge radio close after start")
    text = replace_once(
        text,
        '''    private fun cleanupPlatformObservation(): Boolean {\n        var clean = runCatching(radioPowerObserver::close).isSuccess\n        clean = runCatching(observer::close).isSuccess && clean\n        clean = runCatching { productRuntime.invalidateCellularPlatformFacts() }.isSuccess && clean\n        return clean\n    }\n''',
        '''    private fun cleanupPlatformObservation(): Boolean {\n        var clean = runCatching(observer::close).isSuccess\n        clean = runCatching { productRuntime.invalidateCellularPlatformFacts() }.isSuccess && clean\n        return clean\n    }\n''',
        "bridge cleanup",
    )
    for obsolete in ("radioPowerObserver", "CellularRadioPowerObserver", "observeRadioPowerOff", "rearmNetworkRequest"):
        if obsolete in text:
            raise SystemExit(f"CellularRuntimeBridge still contains obsolete seam {obsolete}")
    write(bridge, text)

    radio = ROOT / "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRadioPowerObserver.kt"
    if not radio.is_file():
        raise SystemExit("CellularRadioPowerObserver.kt missing before asserted deletion")
    radio.unlink()


def strengthen_architecture_guard() -> None:
    path = "tools/check_architecture.py"
    text = read(path)
    text = replace_once(
        text,
        '        "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRadioPowerObserver.kt",\n',
        "",
        "remove deleted observer from adapter list",
    )
    marker = '''    # Native Mesh serving may be stopped by readiness/proxy callbacks already running on the\n'''
    guard = '''    # Candidate A final PRODUCT boundary: one Rust-owned mobile-data detach/attach Rotation.\n    rotation_domain = "crates/rotation/src/lib.rs"\n    rotation_runtime = "crates/runtime/src/rotation_runtime.rs"\n    product_runtime = "crates/runtime/src/product_runtime.rs"\n    product_ffi = "crates/android-ffi/src/product_runtime_ffi.rs"\n    cellular_bridge = "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt"\n    for required in (\n        "DataDisabling",\n        "WaitingCellularLoss",\n        "DataEnabling",\n        "data_disable_mutation_started(",\n        "data_disable_effect_completed(",\n        "data_enable_effect_completed(",\n    ):\n        require(rotation_domain, required, "Candidate A transition semantics must remain Rust-owned")\n    for required in (\n        "settings get global mobile_data",\n        "cmd phone data disable",\n        "cmd phone data enable",\n        "compensation_owned: AtomicBool",\n    ):\n        require(\n            "crates/runtime/src/mobile_data_effect.rs",\n            required,\n            "Candidate A must use one sealed typed effect on the persistent root session",\n        )\n    for target in (rotation_domain, rotation_runtime, product_runtime, product_ffi):\n        for obsolete in (\n            "AirplaneEnabling",\n            "WaitingRadioDown",\n            "AirplaneDisabling",\n            "AirplaneEnableFailed",\n            "AirplaneObservationFailed",\n            "AirplaneDisableFailed",\n            "CellularRequestRearmEffect",\n            "observe_radio_power_off",\n            "observe_platform_cellular_observation",\n        ):\n            forbid(target, obsolete, "Candidate A must not retain an airplane/rearm compatibility path")\n    for target in (rotation_runtime, product_ffi):\n        for obsolete in (\n            "airplane_enable_",\n            "airplane_on_observed",\n            "radio_power_off_observed",\n            "airplane_disable_",\n            "airplane_off_observed",\n            "cellular_request_rearm_",\n            "platform_cellular_observations_after_rearm",\n        ):\n            forbid(target, obsolete, "Candidate A timing vocabulary must describe only the active mobile-data path")\n    for required in (\n        "mobile_data_precondition_observed_ms",\n        "mobile_data_precondition_enabled",\n        "data_disable_started_ms",\n        "data_disable_effect_completed_ms",\n        "cellular_loss_observed_ms",\n        "data_enable_started_ms",\n        "data_enable_effect_completed_ms",\n        "fresh_cellular_observed_ms",\n        "root_authorized_ms",\n    ):\n        require(product_ffi, required, "Android diagnostics must receive the native Candidate A timing projection")\n    forbid_exists(\n        "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRadioPowerObserver.kt",\n        "Candidate A must delete the obsolete Android POWER_OFF observer",\n    )\n    for obsolete in ("NativeCellularRequestRearmEffect", "cellularRequestRearmEffect"):\n        forbid(runtime_controller, obsolete, "Kotlin must not retain a Rotation platform-effect owner")\n    for obsolete in ("CellularRadioPowerObserver", "observeRadioPowerOff", "rearmNetworkRequest"):\n        forbid(cellular_bridge, obsolete, "Kotlin Cellular boundary must remain observation-only")\n    require(\n        runtime_controller,\n        "productRuntime.startPublicIpRotation()",\n        "Kotlin Rotate command must delegate directly to the Rust owner without a platform effect",\n    )\n    require(\n        runtime_controller,\n        "productRuntime.startRemoteControl(spki, controlAuthSigner)",\n        "Kotlin CONTROL startup must not transport a Rotation effect",\n    )\n\n'''
    text = replace_once(text, marker, guard + marker, "insert final Candidate A guard")
    write(path, text)


def final_assertions() -> None:
    # Do not allow the one-shot dev machinery or branch-only compile workflow into the validated head.
    for relative in (
        "tools/apply_candidate_a_boundary_cleanup.py",
        ".github/workflows/candidate-a-boundary-cleanup.yml",
        ".github/workflows/candidate-a-compile.yml",
    ):
        target = ROOT / relative
        if target.exists():
            target.unlink()


def main() -> None:
    cleanup_rotation_domain()
    cleanup_rotation_runtime()
    cleanup_control_runtime()
    cleanup_product_runtime()
    cleanup_ffi()
    cleanup_kotlin()
    strengthen_architecture_guard()
    final_assertions()


if __name__ == "__main__":
    main()
