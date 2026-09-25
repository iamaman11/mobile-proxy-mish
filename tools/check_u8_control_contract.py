#!/usr/bin/env python3
"""Fail-closed U8-E control-plane architecture and protocol guard."""

from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    target = ROOT / path
    if not target.is_file():
        raise SystemExit(f"u8 control contract: required file missing: {path}")
    return target.read_text(encoding="utf-8")


def require(path: str, needle: str, reason: str) -> None:
    if needle not in read(path):
        raise SystemExit(f"u8 control contract: {reason}: {path} lacks {needle!r}")


def forbid(path: str, needle: str, reason: str) -> None:
    if needle in read(path):
        raise SystemExit(f"u8 control contract: {reason}: {path} contains {needle!r}")


def main() -> None:
    control = "crates/control/src/lib.rs"
    runtime = "crates/runtime/src/control_runtime.rs"
    transport = "crates/runtime/src/control_transport.rs"
    rotation = "crates/runtime/src/rotation_runtime.rs"
    product = "crates/runtime/src/product_runtime.rs"
    generation = "crates/runtime/src/product_generation.rs"
    ffi = "crates/android-ffi/src/product_runtime_ffi.rs"
    diagnostics = "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt"
    android = "android/app/src/main/java/com/mobileproxymish/app/AndroidControlIdentity.kt"
    controller = "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt"
    receiver = "android/app/src/main/java/com/mobileproxymish/app/ControlIdentityProvisioningReceiver.kt"
    manifest = "android/app/src/main/AndroidManifest.xml"
    worker = "infra/cloudflare/control-worker/src/index.mjs"
    manager_api = "infra/cloudflare/control-worker/src/manager_api.mjs"
    protocol = "infra/cloudflare/control-worker/src/protocol.mjs"
    wrangler = "infra/cloudflare/control-worker/wrangler.jsonc"
    lab_remote = "lab/windows/diagnose-u8-remote-control.ps1"
    public_egress_observer = "lab/windows/PublicEgressObservation.psm1"
    telephony_detach_observer = "lab/windows/TelephonyDetachObservation.psm1"
    device_cycle = ".github/workflows/device-cycle.yml"

    for needle in (
        'CONTROL_PROTOCOL_VERSION: u8 = 1',
        'ServerControlMessage',
        'RotateIp',
        'encode_accepted_message',
        'operation_id: u64',
        'RemoteRotationResult',
        '"CHANGED"',
        '"UNCHANGED"',
        '"FAILED"',
        '"REJECTED"',
        'CONTROL_WIRE_MAX_BYTES',
    ):
        require(control, needle, "Rust control protocol drifted")
    for forbidden in (
        "GenericCommand",
    ):
        forbid(control, forbidden, "v1 must remain ROTATE_IP-only")

    for needle in (
        "RuntimeExecutor",
        "ControlTransport",
        "const CONTROL_CONNECT_TIMEOUT: Duration = Duration::from_secs(3);",
        "const CONTROL_AUTH_TIMEOUT: Duration = Duration::from_secs(3);",
        "const CONTROL_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(4);",
        'const CONTROL_HEARTBEAT_REQUEST: &str = "MISH_CONTROL_HEARTBEAT_V1";',
        'const CONTROL_HEARTBEAT_RESPONSE: &str = "MISH_CONTROL_HEARTBEAT_ACK_V1";',
        "MissedTickBehavior::Delay",
        "heartbeat_outstanding",
        "record_heartbeat",
        "// A reconnect attempt must never monopolize the public 18 s manager budget.",
        "const CONTROL_RECONNECT_DELAYS_MS: [u64; 5] = [500, 1_000, 2_000, 3_000, 5_000];",
        "CONTROL_RECENT_TERMINAL_REQUESTS: usize = 32",
        "ControlOperationTimingSnapshot",
        "rotation_origin_from_command_ms",
        "RotationRuntimeTimingSnapshot",
        "rotation.prepare(",
        "encode_accepted_message(&request_id, operation_id)",
        "self.write_text_observed(transport, &accepted).await",
        "mark_acceptance_delivery_failed(&mut state, &request_id, operation_id)",
        "rotation.activate_prepared(operation_id)",
        "recent_terminal",
        "ServerControlMessage::ResultAck",
        "result_changed.notify_one()",
        "_ = self.result_changed.notified() => {",
        "// Rotation terminal is a concrete owner event after the intentional radio outage.",
        "failures = 0;",
    ):
        require(runtime, needle, "native control lifecycle/idempotency contract drifted")
    for forbidden in (
        ".outbound_connector(",
        "ProxyConnectTarget",
        "tokio::runtime::Builder",
        "retry_until_changed",
        "retry-until-changed",
        "result_changed.notify_waiters()",
    ):
        forbid(runtime, forbidden, "control must stay ordinary outbound, one-runtime and no retry-until-changed")

    for forbidden in (
        "ControlWebSocket",
        "Sec-WebSocket-Key",
        "Sec-WebSocket-Accept",
        "websocket_client_key",
        "websocket_masking_key",
        "validate_upgrade_response",
        "write_frame(",
        "read_exact(",
        "AsyncReadExt",
        "AsyncWriteExt",
    ):
        forbid(runtime, forbidden, "control_runtime must contain PRODUCT semantics, not RFC6455 mechanics")

    for needle in (
        "ProductTlsClient",
        "lookup_host",
        "TcpStream::connect",
        "client_async_with_config",
        "WebSocketConfig",
        "Message::Text",
        "Message::Binary",
        "CONTROL_WIRE_MAX_BYTES",
    ):
        require(transport, needle, "control transport mechanism drifted")
    for forbidden in (
        "request_id",
        "operation_id",
        "RotateIp",
        "RotationRuntime",
        "CONTROL_RECONNECT_DELAYS_MS",
        "retry_until_changed",
        "MISH_MANAGER_TOKEN",
        "proxy_password",
    ):
        forbid(transport, forbidden, "control transport must not acquire PRODUCT/control-session policy")

    for needle in (
        'futures-util = { version = "=0.3.32", default-features = false, features = ["sink", "std"] }',
        '"macros"',
        'tokio-tungstenite = { version = "=0.30.0", default-features = false, features = ["handshake"] }',
    ):
        require("Cargo.toml", needle, "workspace WebSocket dependencies drifted")
    for forbidden in ("hyper", "tonic", "axum"):
        forbid("Cargo.toml", forbidden, "U8-E must not add a generic HTTP/RPC framework")

    for forbidden in (
        "websocket_client_key",
        "websocket_expected_accept",
        "websocket_masking_key",
        "SHA1_FOR_LEGACY_USE_ONLY",
    ):
        forbid(control, forbidden, "mish-control must own MISH wire semantics, not RFC6455 mechanics")

    runtime_text = read(runtime)
    accepted = runtime_text.find("self.write_text_observed(transport, &accepted).await")
    activate = runtime_text.find("rotation.activate_prepared(operation_id)")
    if accepted < 0 or activate < 0 or accepted >= activate:
        raise SystemExit("u8 control contract: ACCEPTED(operation_id) must flush before rotation activation")

    for needle in (
        "pub fn prepare(",
        "pub fn activate_prepared(",
        "fail_prepared_before_mutation",
        "RotationPhase::Preparing",
        "const ROTATION_SAFETY_DEADLINE: Duration = Duration::from_secs(90);",
    ):
        require(rotation, needle, "Rotation owner must retain acceptance-before-mutation seam")
    forbid(rotation, "retry_until_changed", "Rotation must never retry until public IP changes")

    for needle in (
        "ControlStartInput",
        "control_start: Option<ControlStartInput>",
        "pub fn start_remote_control(",
        "state.control_start.clone()",
    ):
        require(product, needle, "stable PRODUCT lifecycle must retain control configuration across generations")
    for needle in (
        "ControlRuntimeCoordinator",
        "control.shutdown().await",
    ):
        require(generation, needle, "control must be one ProductGeneration-owned capability")

    for needle in (
        "NativeControlAuthSigner",
        "ControlOperationTimingView",
        "RotationRuntimeTimingView",
        "start_remote_control",
        "control_snapshot",
    ):
        require(ffi, needle, "Android FFI control seam drifted")

    for needle in (
        'KeyStore.getInstance(ANDROID_KEY_STORE)',
        'KEY_ALGORITHM_EC',
        'ECGenParameterSpec(CURVE)',
        'CURVE = "secp256r1"',
        'PURPOSE_SIGN',
        'DIGEST_SHA256',
        '.setUserAuthenticationRequired(false)',
        'Signature.getInstance(SIGNATURE_ALGORITHM)',
    ):
        require(android, needle, "control identity must remain non-exportable Android Keystore P-256")
    require(
        android,
        "by lazy(LazyThreadSafetyMode.SYNCHRONIZED)",
        "control identity construction must remain side-effect free before Application attach completes",
    )
    forbid(
        android,
        "private val keyStore = KeyStore.getInstance",
        "AndroidKeyStore must not be opened during MishApplication.attachBaseContext composition",
    )
    for forbidden in (
        "ProxyPassword",
        "proxyPassword",
        "ExternalProxyCredential",
        "SecretKey",
        "getEncoded()",
    ):
        forbid(android, forbidden, "control identity must remain independent from proxy credentials/shared-secret export")

    for needle in (
        "AndroidControlIdentity()",
        "startRemoteControlBestEffort()",
        "productRuntime.startRemoteControl(",
        "currentControlIdentityProvisioningSnapshot",
    ):
        require(controller, needle, "Android controller must remain a thin signing/provisioning adapter")
    for forbidden in (
        "WebSocket(",
        "OkHttp",
        "CoroutineScope(",
        "scheduleAtFixedRate",
        "postDelayed(",
    ):
        forbid(controller, forbidden, "Kotlin must not own control networking/reconnect/scheduling")

    require(receiver, "publicKeySpki", "enrollment must expose only public identity")
    require(receiver, "DUMP-permission-only", "enrollment boundary must remain explicitly privileged")
    require(manifest, 'android:permission="android.permission.DUMP"', "control enrollment receiver must remain DUMP-gated")
    forbid(receiver, "privateKey", "enrollment must never export private control key")
    forbid(receiver, "ProxyPassword", "enrollment must never export proxy credentials")

    for needle in (
        "this.ctx.acceptWebSocket(server)",
        "serializeAttachment",
        "deserializeAttachment",
        "this.ctx.getWebSockets()",
        "verifyDeviceSignature",
        "isFreshAuthChallenge",
        "challenge_issued_at_ms",
        "public_key_spki_b64",
        '"BUSY"',
        '"DEVICE_OFFLINE"',
        '"active_operation"',
        '"recent_operations"',
        "MAX_RECENT_OPERATIONS",
        "resultAckMessage",
        'const MANAGER_ROTATE = "/v1/rotate"',
        'const CONTROL_HOST = "mish.alegria.by"',
        "url.hostname !== CONTROL_HOST",
        'const PRIMARY_DEVICE_OBJECT = "primary"',
        '"https://control.internal/manager/rotate-and-wait"',
        "newManagerRequestId()",
        "rotateAndWait",
        "dispatchRotation",
        "waitForTerminal",
        "scheduler",
        "PRODUCT_ROTATION_SAFETY_MS = 90_000",
        "ACCEPTED_RESULT_LEASE_MS",
        "DELIVERY_ACK_MS = 2_000",
        "NATURAL_RECONNECT_RECOVERY_MS",
        '"RECOVERING"',
        "delivery_attempts",
        "redeliverRecoveredOperation",
        "rotateMessage(active.request_id)",
        "FENCED_DRAIN_MS",
        'CONTROL_HEARTBEAT_REQUEST = "MISH_CONTROL_HEARTBEAT_V1"',
        'CONTROL_HEARTBEAT_RESPONSE = "MISH_CONTROL_HEARTBEAT_ACK_V1"',
        "CONTROL_SESSION_FRESHNESS_MS = 10_000",
        "setWebSocketAutoResponse",
        "getWebSocketAutoResponseTimestamp",
        "authenticated_at_ms",
        "freshAuthenticatedSocket",
        "closeStaleAuthenticatedSockets",
        '"FENCED"',
        "this.ctx.storage.setAlarm(",
        "this.ctx.storage.deleteAlarm()",
        "async alarm()",
        "reconcileActiveOperation",
        "finalizeUnknown",
        "fenceAuthenticatedSockets",
    ):
        require(worker, needle, "Durable Object broker/hibernation contract drifted")
    # Continuous liveness is native-owned. Manager requests never become reconnect owners.
    require(
        runtime,
        "CONTROL_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(4)",
        "Rust/Tokio control owner must continuously prove WSS liveness",
    )
    require(
        worker,
        "CONTROL_SESSION_FRESHNESS_MS = 10_000",
        "Worker must dispatch only to a recently proven control session",
    )

    for forbidden in (
        "Workers VPC",
        "cloudflared",
        "proxy_password",
        "ProxyPassword",
        "offline_queue",
        "setInterval(",
        "setTimeout(",
        "INITIAL_DELIVERY_ACK_MS",
        "RECOVERY_DELIVERY_ACK_MS",
        "recoverAuthenticatedSockets",
        "delivery_recovery_count",
        "/manager/operation",
        'match[2] === "rotate"',
    ):
        forbid(worker, forbidden, "Worker/DO must remain a narrow broker with no proxy secret/VPC/polling loop")

    for needle in (
        'MANAGER_ROTATE_SCHEMA = "mish.control.rotate/v1"',
        'MANAGER_ROTATE_WAIT_TIMEOUT_MS = 18_000',
        '"CHANGED"',
        '"UNCHANGED"',
        '"FAILED"',
        '"REJECTED"',
        '"UNKNOWN"',
        '"UNAUTHORIZED"',
        '"DEVICE_OFFLINE"',
        '"BUSY"',
        '"TIMEOUT"',
        '"INTERNAL_ERROR"',
        "retryable",
        "dispatched",
        "device_online",
        "operation_id",
        "timing",
    ):
        require(manager_api, needle, "public manager response contract drifted")
    for forbidden in (
        "device_id",
        "MISH_MANAGER_TOKEN",
        "setInterval(",
        "setTimeout(",
    ):
        forbid(manager_api, forbidden, "manager API schema must not acquire device routing, secrets or polling")

    for needle in (
        'AUTH_DOMAIN = "MISH_CONTROL_AUTH_V1"',
        "crypto.subtle.importKey",
        '"ECDSA"',
        '"P-256"',
        "crypto.subtle.verify",
        "managerAuthorized",
        "DEVICE_AUTH_CHALLENGE_MAX_AGE_MS",
        "isFreshAuthChallenge",
        "crypto.subtle.digest",
        "parseManagerRotateBody",
        "parseEnrollmentBody",
    ):
        require(protocol, needle, "Worker authentication protocol drifted")

    for needle in (
        "[ValidateRange(20, 120)][int] $TerminalTimeoutSeconds = 20",
        "'control_snapshot_v1'",
        "$idleProofSeconds = 12",
        "CONTROL_HEARTBEAT_NOT_ADVANCING",
        "CONTROL_RECONNECTED_DURING_IDLE",
        "CONTROL_SESSION_NOT_LONG_LIVED",
        "$managerDurationMs -gt 18000",
        "idle_liveness_proof = $true",
        "heartbeat_delta = $heartbeatDelta",
        "device_timeline_proof = $true",
        "rotation_terminal_from_command_ms",
        "result_ack_ms",
        "fresh_cellular_generation",
        "root_authorized_generation",
        "PublicEgressObservation.psm1",
        "external_public_ip_observer_proof = $true",
        "external_public_ip_consensus",
        "EXTERNAL_PUBLIC_IP_RESULT_MISMATCH",
        "MISH_U8_REMOTE_CONTROL_EXTERNAL_PUBLIC_IP=PASS",
        "U8_REMOTE_CONTROL_MANAGER_TIMEOUT_DIAGNOSTIC",
        "MISH_U8_REMOTE_CONTROL_TIMEOUT_DIAGNOSTIC=CAPTURED",
        "device_timeline_at_timeout",
        "product_snapshot_capture",
        "operation_polls = 0",
        "no retry or polling was issued",
        "client_bound_seconds = $TerminalTimeoutSeconds",
    ):
        require(
            lab_remote,
            needle,
            "LAB/WSL acceptance must prove long-lived heartbeat freshness within the 20 second response ceiling",
        )
    for needle in (
        "idle_liveness_proof",
        "heartbeat_delta",
        "reconnect_count_after_idle",
        "long_lived_session_age_ms",
        "manager_duration_ms",
        "external_public_ip_observer_proof",
        "external_public_ip_consensus",
        "device_timeline_proof",
        "device_timeline.rotation_terminal_from_command_ms",
        "client_bound_seconds",
    ):
        require(
            device_cycle,
            needle,
            "Device Cycle must enforce the long-lived CONTROL acceptance evidence",
        )

    for needle in (
        "https://checkip.amazonaws.com/",
        "CredentialProvisioning.psm1",
        "Invoke-MishExternalProxyCredentialProvisioning",
        "Open-MishExternalProxyCredentialLease",
        "New-MishPublicEgressObservationContext",
        "Invoke-MishExternalPublicIpObservation",
        "Close-MishPublicEgressObservationContext",
        "'forward', 'tcp:0', 'tcp:3128'",
        "'forward', '--remove'",
    ):
        require(
            public_egress_observer,
            needle,
            "shared LAB public-egress observer drifted",
        )
    for forbidden in (
        "diagnose-u5-rotation.ps1",
        "start_public_ip_rotation",
        "MISH_MANAGER_TOKEN",
        "ROTATE_IP",
        "/v1/rotate",
        "airplane-mode enable",
        "airplane-mode disable",
    ):
        forbid(
            public_egress_observer,
            forbidden,
            "shared LAB public-egress observer must stay read-only and CONTROL-independent",
        )

    for needle in (
        '"operation_timing"',
        '"REMOTE_COMMAND_RECEIVED"',
        '"rotation_origin_from_command_ms"',
        '"result_ack_ms"',
    ):
        require(
            diagnostics,
            needle,
            "DUMP-only diagnostics must project operation timing evidence",
        )
    for forbidden in (
        '"request_id"',
        '"before_ip_address"',
        '"after_ip_address"',
    ):
        forbid(
            diagnostics,
            forbidden,
            "diagnostics must expose timings without request ids or raw public IP",
        )

    for needle in (
        "CollectTelephonyDetachEvidence",
        "Start-MishTelephonyDetachObservation",
        "Stop-MishTelephonyDetachObservation",
        "New-MishTelephonyDetachResearchProjection",
        "telephony_detach_research = $radioDetachResearch",
    ):
        require(
            lab_remote,
            needle,
            "remote-control research must reuse the one existing manager Rotation and add observation only",
        )
    for needle in (
        "u8_radio_detach_research",
        "mish-u8-telephony-detach-v1.json",
        "U8_RADIO_DETACH_RESEARCH_INVALID",
    ):
        require(
            device_cycle,
            needle,
            "Device Cycle must expose one explicit typed radio-detach research probe",
        )
    for needle in (
        "'mish.lab.telephony-detach-research/v1'",
        "'PhoneStateListener.LISTEN_SERVICE_STATE'",
        "'POWER_OFF'",
        "second_rotation_triggered = $false",
        "product_mutation_performed = $false",
        "radio_mutation_performed = $false",
        "runtime_permission_mutation_performed = $false",
    ):
        require(
            telephony_detach_observer,
            needle,
            "telephony detach projection must remain a read-only exact-operation observation",
        )
    for forbidden in (
        "/v1/rotate",
        "MISH_MANAGER_TOKEN",
        "ROTATE_IP",
        "airplane-mode enable",
        "airplane-mode disable",
        "Start-Sleep",
        "Thread.Sleep",
        "'shell', 'pm', 'grant'",
        "'shell', 'pm', 'revoke'",
    ):
        forbid(
            telephony_detach_observer,
            forbidden,
            "typed telephony observer must not acquire manager, radio-effect, retry or dwell ownership",
        )

    config = json.loads(
        "\n".join(
            line for line in read(wrangler).splitlines()
            if not line.lstrip().startswith("//")
        )
    )
    if config.get("compatibility_date") != "2026-09-22":
        raise SystemExit("u8 control contract: Worker compatibility date must remain explicit")
    if config.get("workers_dev") is not False:
        raise SystemExit("u8 control contract: control Worker must not expose a workers.dev endpoint")
    if config.get("routes") != [{"pattern": "mish.alegria.by", "custom_domain": True}]:
        raise SystemExit(
            "u8 control contract: Worker must own only the exact mish.alegria.by custom domain"
        )
    if config.get("secrets", {}).get("required") != ["MISH_MANAGER_TOKEN"]:
        raise SystemExit("u8 control contract: manager token must be a required Worker secret")
    if "vars" in config:
        raise SystemExit("u8 control contract: sensitive manager auth must not migrate to Wrangler vars")
    exported = config.get("exports", {}).get("DeviceControl", {})
    if exported.get("type") != "durable-object" or exported.get("storage") != "sqlite":
        raise SystemExit("u8 control contract: new DeviceControl must remain a SQLite Durable Object")
    bindings = config.get("durable_objects", {}).get("bindings", [])
    if bindings != [{"name": "DEVICE_CONTROL", "class_name": "DeviceControl"}]:
        raise SystemExit("u8 control contract: Durable Object binding drifted")

    for path in (
        control,
        runtime,
        transport,
        android,
        controller,
        receiver,
        worker,
        manager_api,
        protocol,
        wrangler,
    ):
        text = read(path).lower()
        for forbidden_secret in (
            "-----begin private key-----",
            "bearer sk-",
            "mish_manager_token =",
            "proxy_password =",
        ):
            if forbidden_secret in text:
                raise SystemExit(f"u8 control contract: secret material detected in {path}")

    print("U8_CONTROL_CONTRACT=PASS")


if __name__ == "__main__":
    main()
