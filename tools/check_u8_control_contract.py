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
    android = "android/app/src/main/java/com/mobileproxymish/app/AndroidControlIdentity.kt"
    controller = "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt"
    receiver = "android/app/src/main/java/com/mobileproxymish/app/ControlIdentityProvisioningReceiver.kt"
    manifest = "android/app/src/main/AndroidManifest.xml"
    worker = "infra/cloudflare/control-worker/src/index.mjs"
    manager_api = "infra/cloudflare/control-worker/src/manager_api.mjs"
    protocol = "infra/cloudflare/control-worker/src/protocol.mjs"
    wrangler = "infra/cloudflare/control-worker/wrangler.jsonc"

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
        "const CONTROL_CONNECT_TIMEOUT: Duration = Duration::from_secs(15);",
        "const CONTROL_AUTH_TIMEOUT: Duration = Duration::from_secs(10);",
        "const CONTROL_RECONNECT_DELAYS_MS: [u64; 5] = [1_000, 5_000, 15_000, 30_000, 60_000];",
        "CONTROL_RECENT_TERMINAL_REQUESTS: usize = 32",
        "rotation.prepare(",
        "encode_accepted_message(&request_id, operation_id)",
        "self.write_text_observed(transport, &accepted).await",
        "mark_acceptance_delivery_failed(&mut state, &request_id, operation_id)",
        "rotation.activate_prepared(operation_id)",
        "recent_terminal",
        "ServerControlMessage::ResultAck",
        "result_changed.notify_one()",
    ):
        require(runtime, needle, "native control lifecycle/idempotency contract drifted")
    for forbidden in (
        ".outbound_connector(",
        "ProxyConnectTarget",
        "const CONTROL_HEARTBEAT_INTERVAL",
        'write_text("PING")',
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
        'const PRIMARY_DEVICE_OBJECT = "primary"',
        '"https://control.internal/manager/rotate-and-wait"',
        "newManagerRequestId()",
        "rotateAndWait",
        "dispatchRotation",
        "waitForTerminal",
        "scheduler",
        "PRODUCT_ROTATION_SAFETY_MS = 90_000",
        "ACCEPTED_RESULT_LEASE_MS",
        "INITIAL_DELIVERY_ACK_MS = 10_000",
        "RECOVERY_DELIVERY_ACK_MS = 40_000",
        "recoverAuthenticatedSockets",
        "FENCED_DRAIN_MS",
        '"FENCED"',
        "this.ctx.storage.setAlarm(",
        "this.ctx.storage.deleteAlarm()",
        "async alarm()",
        "reconcileActiveOperation",
        "finalizeUnknown",
        "fenceAuthenticatedSockets",
    ):
        require(worker, needle, "Durable Object broker/hibernation contract drifted")
    # Cross-layer delivery recovery budget is intentional, not an arbitrary Worker timeout:
    # PRODUCT first reconnect after READY may use 1 s backoff + 15 s connect +
    # 10 s challenge + 10 s READY = 36 s. Worker retains 4 s scheduling/wire margin
    # while 10 s initial + 40 s recovery remains below the 55 s manager HTTP bound.
    require(
        worker,
        "RECOVERY_DELIVERY_ACK_MS = 40_000",
        "Worker recovery ACK must cover the pinned 36 s PRODUCT reconnect/auth budget",
    )

    for forbidden in (
        "Workers VPC",
        "cloudflared",
        "proxy_password",
        "ProxyPassword",
        "offline_queue",
        "setInterval(",
        "setTimeout(",
        "/manager/operation",
        'match[2] === "rotate"',
    ):
        forbid(worker, forbidden, "Worker/DO must remain a narrow broker with no proxy secret/VPC/polling loop")

    for needle in (
        'MANAGER_ROTATE_SCHEMA = "mish.control.rotate/v1"',
        'MANAGER_ROTATE_WAIT_TIMEOUT_MS = 55_000',
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
    if config.get("routes") != [{"pattern": "api.alegria.by", "custom_domain": True}]:
        raise SystemExit("u8 control contract: control Worker must own only the exact api.alegria.by custom domain")
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
