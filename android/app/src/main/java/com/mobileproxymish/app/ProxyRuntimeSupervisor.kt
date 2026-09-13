package com.mobileproxymish.app

import android.content.Context
import android.os.Process as AndroidProcess
import android.system.Os
import android.util.Base64
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.app.cellular.SuProcess
import com.mobileproxymish.ffi.CellularBridgeRuntime
import com.mobileproxymish.ffi.RuntimeProcessFailure
import com.mobileproxymish.ffi.RuntimeProcessLifecycleController
import com.mobileproxymish.ffi.RuntimeProcessSnapshotView
import com.mobileproxymish.ffi.RuntimeProcessState
import com.mobileproxymish.ffi.proxyListenerPorts
import com.mobileproxymish.ffi.renderProxyRuntimeConfig
import java.io.Closeable
import java.io.FileOutputStream
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

private const val LOOPBACK_HEALTH_FAILURE_CONFIRMATIONS = 3

/** Runtime Lifecycle projection only; it does not own proxy protocol or cellular facts. */
sealed interface ProxyRuntimeSnapshot {
    data object Stopped : ProxyRuntimeSnapshot
    data object Starting : ProxyRuntimeSnapshot
    data object Running : ProxyRuntimeSnapshot

    data class Failed(
        val reason: RuntimeProcessFailure,
    ) : ProxyRuntimeSnapshot
}

/**
 * Non-secret read-only observation of the exact currently owned runtime generation.
 *
 * This is diagnostic evidence only. It carries no credential material, no configuration and no
 * readiness authority; the existing lifecycle, Credentials and Cellular Egress owners remain
 * authoritative.
 */
internal data class ProxyRuntimeDiagnosticObservation(
    val childAlive: Boolean,
    val privateBridgePort: Int?,
    val privateBridgeHealthy: Boolean,
    val credentialVersion: ULong?,
)

/** In-memory only external proxy credential material. */
internal class ProxyRuntimeCredentials(
    val username: String,
    val password: String,
) {
    override fun toString(): String = "ProxyRuntimeCredentials(<redacted>)"
}

/** Exact Credentials-owner version plus ephemeral derived material for one runtime start. */
internal class ProxyRuntimeCredentialSnapshot(
    val version: ULong,
    val credentials: ProxyRuntimeCredentials,
) {
    override fun toString(): String = "ProxyRuntimeCredentialSnapshot(version=$version,<redacted>)"
}

/** Narrow composition input; credential lifecycle and durable semantics remain in Rust. */
internal fun interface ProxyCredentialProvider {
    fun currentCredential(): ProxyRuntimeCredentialSnapshot?
}

private fun randomCredential(): String {
    val bytes = ByteArray(CREDENTIAL_BYTES)
    SECURE_RANDOM.nextBytes(bytes)
    return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
}

/** A single local health timeout is not sufficient evidence that an owned listener died. */
internal fun confirmedLoopbackHealthFailure(consecutiveFailures: Int): Boolean =
    consecutiveFailures >= LOOPBACK_HEALTH_FAILURE_CONFIRMATIONS

/**
 * Android child-process effect adapter for the Rust Runtime Lifecycle natural owner.
 *
 * canonical loopback sing-box listeners
 *   -> private loopback SOCKS bridge
 *   -> the exact Cellular Egress owner
 *
 * ProcessBuilder/files/Android PID effects remain here. STARTING/RUNNING/FAILED/STOPPED and
 * failure reason state are owned by `mish-runtime` and exposed through the typed UniFFI seam.
 */
class ProxyRuntimeSupervisor internal constructor(
    context: Context,
    private val cellularRuntime: CellularRuntimeBridge,
    private val publicCredentials: ProxyCredentialProvider,
    private val onRecoverableUnexpectedFailure: (RuntimeProcessFailure) -> Unit = {},
) : Closeable {
    private val appContext = context.applicationContext
    private val runtimeDir = File(appContext.noBackupFilesDir, RUNTIME_DIR)
    private val generationManifestFile = File(runtimeDir, GENERATION_MANIFEST_FILE)
    private var configFile = File(runtimeDir, LEGACY_CONFIG_FILE)
    private var pidFile = File(runtimeDir, LEGACY_PID_FILE)
    private var rootLauncherFile = File(runtimeDir, LEGACY_ROOT_LAUNCHER_FILE)
    private var rootControlFile = File(runtimeDir, LEGACY_ROOT_CONTROL_FILE)
    private var activeGenerationId: String? = null
    private val binaryFile = File(appContext.applicationInfo.nativeLibraryDir, SING_BOX_LIBRARY)
    private val lifecycle = RuntimeProcessLifecycleController()
    private val mutableSnapshot = MutableStateFlow(projectLifecycle(lifecycle.snapshot()))
    private val closed = AtomicBoolean(false)
    private val lock = Any()
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-proxy-runtime").apply { isDaemon = true }
    }

    private var child: Process? = null
    private var childPid: Int? = null
    private var bridge: CellularBridgeRuntime? = null
    private var servingCredentialVersion: ULong? = null
    private var monitor: Thread? = null
    private var stopping = false

    val snapshot: StateFlow<ProxyRuntimeSnapshot>
        get() = mutableSnapshot.asStateFlow()

    internal fun diagnosticObservation(): ProxyRuntimeDiagnosticObservation = synchronized(lock) {
        val currentChild = child
        val currentBridge = bridge
        ProxyRuntimeDiagnosticObservation(
            childAlive = currentChild != null && canonicalLoopbackListenersReachable(),
            privateBridgePort = runCatching { currentBridge?.port()?.toInt() }.getOrNull(),
            privateBridgeHealthy = currentBridge?.let {
                runCatching { it.isHealthy() }.getOrDefault(false)
            } == true,
            credentialVersion = servingCredentialVersion,
        )
    }

    fun start() {
        if (closed.get() || !lifecycle.requestStart()) return
        publishLifecycle()
        try {
            executor.execute(::startBlocking)
        } catch (_: RejectedExecutionException) {
            failLifecycle(RuntimeProcessFailure.CHILD_EXECUTOR_REJECTED)
        }
    }

    private fun startBlocking() {
        synchronized(lock) {
            if (closed.get()) return
            if (!runtimeDir.isDirectory && !runtimeDir.mkdirs()) {
                failLifecycle(RuntimeProcessFailure.CONFIGURATION_REJECTED)
                return
            }
            if (!binaryFile.isFile || !binaryFile.canExecute()) {
                failLifecycle(RuntimeProcessFailure.NATIVE_RUNTIME_MISSING)
                return
            }
            if (!loadRecordedGeneration() || !cleanupStaleChild()) {
                failLifecycle(RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH)
                return
            }
            if (!createNextGeneration()) {
                failLifecycle(RuntimeProcessFailure.CONFIGURATION_REJECTED)
                return
            }

            // Resolve exact durable-owner version + derived material before opening the private
            // Cellular Egress bridge. Only the version survives as a non-secret serving fact.
            val publicCredential = try {
                publicCredentials.currentCredential()
            } catch (_: Exception) {
                null
            }
            if (publicCredential == null) {
                deleteCurrentGenerationFiles(removeManifest = true)
                failLifecycle(RuntimeProcessFailure.EXTERNAL_CREDENTIAL_UNAVAILABLE)
                return
            }

            // Private bridge credentials stay intentionally ephemeral and generation-scoped.
            val privateUsername = randomCredential()
            val privatePassword = randomCredential()

            val newBridge = try {
                cellularRuntime.startPrivateBridge(
                    username = privateUsername,
                    password = privatePassword,
                    operationTimeoutMs = OUTBOUND_TIMEOUT_MS.toULong(),
                )
            } catch (_: Exception) {
                deleteCurrentGenerationFiles(removeManifest = true)
                failLifecycle(RuntimeProcessFailure.PRIVATE_BRIDGE_UNAVAILABLE)
                return
            }

            val config = try {
                renderProxyRuntimeConfig(
                    listenAddress = LOOPBACK,
                    publicUsername = publicCredential.credentials.username,
                    publicPassword = publicCredential.credentials.password,
                    bridgePort = newBridge.port(),
                    bridgeUsername = privateUsername,
                    bridgePassword = privatePassword,
                )
            } catch (_: Exception) {
                runCatching { newBridge.stop() }
                deleteCurrentGenerationFiles(removeManifest = true)
                failLifecycle(RuntimeProcessFailure.CONFIGURATION_REJECTED)
                return
            }

            if (!writePrivateConfig(config)) {
                runCatching { newBridge.stop() }
                deleteCurrentGenerationFiles(removeManifest = true)
                failLifecycle(RuntimeProcessFailure.CONFIGURATION_REJECTED)
                return
            }

            if (!writeRootLauncher()) {
                runCatching { newBridge.stop() }
                deleteCurrentGenerationFiles(removeManifest = true)
                failLifecycle(RuntimeProcessFailure.CHILD_PROCESS_START_FAILED)
                return
            }
            val newChild = try {
                SuProcess.serializedRootSession {
                    ProcessBuilder(
                        MAGISK_SU,
                        "-c",
                        rootLauncherFile.absolutePath,
                    )
                        .directory(runtimeDir)
                        .redirectErrorStream(true)
                        .start()
                }
            } catch (_: Exception) {
                runCatching { newBridge.stop() }
                deleteCurrentGenerationFiles(removeManifest = true)
                failLifecycle(RuntimeProcessFailure.CHILD_PROCESS_START_FAILED)
                return
            }

            // `su -c` is only the launcher process, not the long-lived sing-box child. Magisk
            // need not close that parent receipt before the detached child has written its exact
            // PID record, so the bounded record below is the authoritative launch receipt.
            val newPid = awaitRecordedPid()
            if (newPid == null) {
                terminateProcess(newChild, newPid)
                runCatching { newBridge.stop() }
                deleteCurrentGenerationFiles(removeManifest = true)
                failLifecycle(RuntimeProcessFailure.CHILD_PID_OR_PERSISTENCE_FAILED)
                return
            }
            drainOutput(newChild)

            if (!waitForHealthy(newBridge)) {
                terminateProcess(newChild, newPid)
                runCatching { newBridge.stop() }
                deleteCurrentGenerationFiles(removeManifest = true)
                failLifecycle(RuntimeProcessFailure.HEALTH_CHECK_FAILED)
                return
            }

            // The child has consumed its configuration. Keep only the private PID/control
            // identity needed for bounded root lifecycle control; credentials do not persist.
            if (!deleteIfPresent(configFile)) {
                terminateProcess(newChild, newPid)
                runCatching { newBridge.stop() }
                deleteCurrentGenerationFiles(removeManifest = true)
                failLifecycle(RuntimeProcessFailure.CLEANUP_FAILED)
                return
            }

            if (closed.get()) {
                terminateProcess(newChild, newPid)
                runCatching { newBridge.stop() }
                deleteCurrentGenerationFiles(removeManifest = true)
                stopLifecycle()
                return
            }

            child = newChild
            childPid = newPid
            bridge = newBridge
            servingCredentialVersion = publicCredential.version
            stopping = false
            check(lifecycle.markRunning()) { "proxy runtime left STARTING before health publication" }
            publishLifecycle()
            startMonitor(newChild, newBridge)
        }
    }

    private fun startMonitor(expectedChild: Process, expectedBridge: CellularBridgeRuntime) {
        val thread = Thread({
            var consecutiveLoopbackFailures = 0
            while (!closed.get()) {
                val reason = when {
                    !runCatching { expectedBridge.isHealthy() }.getOrDefault(false) ->
                        RuntimeProcessFailure.PRIVATE_BRIDGE_UNHEALTHY
                    canonicalLoopbackListenersReachable() -> {
                        consecutiveLoopbackFailures = 0
                        null
                    }
                    else -> {
                        consecutiveLoopbackFailures += 1
                        if (!confirmedLoopbackHealthFailure(consecutiveLoopbackFailures)) {
                            null
                        } else if (isExactRootSingBoxAlive(childPid ?: -1)) {
                            RuntimeProcessFailure.HEALTH_CHECK_FAILED
                        } else {
                            RuntimeProcessFailure.CHILD_EXITED
                        }
                    }
                }
                if (reason != null) {
                    try {
                        executor.execute {
                            synchronized(lock) {
                                if (!stopping && child === expectedChild) {
                                    val cleanupOk = cleanupCurrentLocked()
                                    val published = if (cleanupOk) reason else RuntimeProcessFailure.CLEANUP_FAILED
                                    failLifecycle(published)
                                    if (published in RECOVERABLE_UNEXPECTED_FAILURES) {
                                        onRecoverableUnexpectedFailure(published)
                                    }
                                }
                            }
                        }
                    } catch (_: RejectedExecutionException) {
                        // close() already owns terminal cleanup.
                    }
                    return@Thread
                }
                try {
                    Thread.sleep(HEALTH_POLL_MS)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
        }, "mish-proxy-runtime-monitor")
        thread.isDaemon = true
        monitor = thread
        thread.start()
    }

    private fun waitForHealthy(privateBridge: CellularBridgeRuntime): Boolean {
        val publicPorts = try {
            proxyListenerPorts().map { it.toInt() }
        } catch (_: LinkageError) {
            return false
        } catch (_: Exception) {
            return false
        }
        if (publicPorts.isEmpty()) return false

        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(START_HEALTH_TIMEOUT_SECONDS)
        while (System.nanoTime() < deadline) {
            val recordedPid = awaitRecordedPid()
            if (recordedPid == null || !isExactRootSingBoxAlive(recordedPid)) {
                return false
            }
            if (!runCatching { privateBridge.isHealthy() }.getOrDefault(false)) {
                return false
            }
            if (publicPorts.all(::canConnectLoopback)) return true
            Thread.sleep(HEALTH_RETRY_MS)
        }
        return false
    }

    private fun canConnectLoopback(port: Int): Boolean = try {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(LOOPBACK, port), HEALTH_CONNECT_TIMEOUT_MS)
        }
        true
    } catch (_: Exception) {
        false
    }

    private fun writePrivateConfig(config: String): Boolean = try {
        runtimeDir.mkdirs()
        configFile.writeText(config, Charsets.UTF_8)
        Os.chmod(configFile.absolutePath, PRIVATE_FILE_MODE)
        true
    } catch (_: Exception) {
        false
    }

    private fun canonicalLoopbackListenersReachable(): Boolean = try {
        proxyListenerPorts().map { it.toInt() }.all(::canConnectLoopback)
    } catch (_: Exception) {
        false
    }

    private fun loadRecordedGeneration(): Boolean = try {
        if (!generationManifestFile.isFile) {
            activeGenerationId = null
            configFile = File(runtimeDir, LEGACY_CONFIG_FILE)
            pidFile = File(runtimeDir, LEGACY_PID_FILE)
            rootLauncherFile = File(runtimeDir, LEGACY_ROOT_LAUNCHER_FILE)
            rootControlFile = File(runtimeDir, LEGACY_ROOT_CONTROL_FILE)
            return true
        }
        val id = generationManifestFile.readText(Charsets.US_ASCII)
            .lineSequence()
            .firstOrNull { it.startsWith("generation=") }
            ?.substringAfter("generation=")
            ?: return false
        if (!GENERATION_ID.matches(id)) return false
        selectGeneration(id)
        true
    } catch (_: Exception) {
        false
    }

    private fun createNextGeneration(): Boolean = try {
        val id = randomCredential().take(GENERATION_ID_LENGTH)
        if (!GENERATION_ID.matches(id)) return false
        selectGeneration(id)
        val temporary = File(runtimeDir, "$GENERATION_MANIFEST_FILE.tmp")
        FileOutputStream(temporary).use { output ->
            output.write("generation=$id\n".toByteArray(Charsets.US_ASCII))
            output.fd.sync()
        }
        Os.chmod(temporary.absolutePath, PRIVATE_FILE_MODE)
        if (!temporary.renameTo(generationManifestFile)) return false
        Os.chmod(generationManifestFile.absolutePath, PRIVATE_FILE_MODE)
        true
    } catch (_: Exception) {
        false
    }

    private fun selectGeneration(id: String) {
        activeGenerationId = id
        configFile = File(runtimeDir, "sing-box-$id.json")
        pidFile = File(runtimeDir, "sing-box-$id.pid")
        rootLauncherFile = File(runtimeDir, "sing-box-$id-launch.sh")
        rootControlFile = File(runtimeDir, "sing-box-$id-control.sh")
    }

    private fun deleteCurrentGenerationFiles(removeManifest: Boolean): Boolean {
        var clean = true
        if (!deleteIfPresent(configFile)) clean = false
        if (!deleteIfPresent(pidFile)) clean = false
        if (!deleteIfPresent(rootLauncherFile)) clean = false
        if (!deleteIfPresent(rootControlFile)) clean = false
        if (removeManifest && !deleteIfPresent(generationManifestFile)) clean = false
        if (clean) activeGenerationId = null
        return clean
    }

    private fun writeRootLauncher(): Boolean = try {
        val appUid = AndroidProcess.myUid()
        if (!isSafeOwnedPath(configFile) || !isSafeOwnedPath(pidFile) || !isSafeNativePath(binaryFile)) {
            return false
        }
        rootLauncherFile.writeText(
            """
            #!/system/bin/sh
            umask 077
            /system/bin/toybox nohup "${binaryFile.absolutePath}" run -c "${configFile.absolutePath}" </dev/null >/dev/null 2>&1 &
            child_pid="${'$'}!"
            case "${'$'}child_pid" in ''|*[!0-9]*) exit 124;; esac
            printf '%s\n' "${'$'}child_pid" > "${pidFile.absolutePath}" || exit 125
            chown $appUid:$appUid "${pidFile.absolutePath}" || exit 126
            chmod 600 "${pidFile.absolutePath}" || exit 127
            exit 0
            """.trimIndent() + "\n",
            Charsets.UTF_8,
        )
        Os.chmod(rootLauncherFile.absolutePath, ROOT_SCRIPT_MODE)
        true
    } catch (_: Exception) {
        false
    }

    private fun writeRootControl(action: String): Boolean = try {
        if (action !in ROOT_ACTIONS || !isSafeOwnedPath(configFile) || !isSafeOwnedPath(pidFile) ||
            !isSafeNativePath(binaryFile)
        ) return false
        rootControlFile.writeText(
            """
            #!/system/bin/sh
            set -eu
            pid="${'$'}(cat "${pidFile.absolutePath}")"
            case "${'$'}pid" in ''|*[!0-9]*) exit 64;; esac
            [ -r "/proc/${'$'}pid/cmdline" ] || exit 20
            actual="${'$'}(tr '\000' ' ' < "/proc/${'$'}pid/cmdline")"
            case "${'$'}actual" in *"/${SING_BOX_LIBRARY} run -c ${configFile.absolutePath}"*) ;; *) exit 21;; esac
            case "$action" in
              status) exit 0 ;;
              stop)
                kill -TERM "${'$'}pid" 2>/dev/null || exit 3
                i=0
                while [ "${'$'}i" -lt 60 ]; do
                  [ ! -d "/proc/${'$'}pid" ] && exit 0
                  sleep 0.05
                  i=${'$'}((i + 1))
                done
                kill -KILL "${'$'}pid" 2>/dev/null || exit 4
                i=0
                while [ "${'$'}i" -lt 40 ]; do
                  [ ! -d "/proc/${'$'}pid" ] && exit 0
                  sleep 0.05
                  i=${'$'}((i + 1))
                done
                exit 5
                ;;
            esac
            """.trimIndent() + "\n",
            Charsets.UTF_8,
        )
        Os.chmod(rootControlFile.absolutePath, ROOT_SCRIPT_MODE)
        true
    } catch (_: Exception) {
        false
    }

    private fun isSafeOwnedPath(file: File): Boolean = file.absolutePath
        .let { it.startsWith(runtimeDir.absolutePath + "/") && SAFE_PATH.matches(it) }

    private fun isSafeNativePath(file: File): Boolean = file.absolutePath
        .let { it.startsWith(appContext.applicationInfo.nativeLibraryDir + "/") && SAFE_PATH.matches(it) }

    private fun awaitRecordedPid(): Int? {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(PID_RECORD_TIMEOUT_MS)
        while (System.nanoTime() < deadline) {
            val pid = runCatching { pidFile.readText(Charsets.US_ASCII).trim().toIntOrNull() }.getOrNull()
            if (pid != null && pid > 0) return pid
            Thread.sleep(PID_RECORD_RETRY_MS)
        }
        return null
    }

    private fun cleanupStaleChild(): Boolean {
        if (!pidFile.isFile) return deleteCurrentGenerationFiles(removeManifest = activeGenerationId != null)
        val pid = pidFile.readText(Charsets.US_ASCII).trim().toIntOrNull() ?: return false
        if (!isExactRootSingBoxAlive(pid)) return deleteCurrentGenerationFiles(activeGenerationId != null)
        if (!stopExactRootSingBox(pid)) return false
        return deleteCurrentGenerationFiles(activeGenerationId != null)
    }

    private fun isExactRootSingBoxAlive(pid: Int): Boolean = runRootControl("status", pid) == 0

    private fun stopExactRootSingBox(pid: Int): Boolean =
        runRootControl("stop", pid) in setOf(0, ROOT_CONTROL_PROCESS_ABSENT)

    private fun runRootControl(action: String, pid: Int): Int {
        if (pid <= 0 || action !in ROOT_ACTIONS) return -1
        val recorded = runCatching { pidFile.readText(Charsets.US_ASCII).trim().toIntOrNull() }.getOrNull()
        if (recorded != pid || !writeRootControl(action)) return -1
        return runCatching {
            SuProcess().run(listOf(MAGISK_SU, "-c", rootControlFile.absolutePath)).let { result ->
                if (!result.timedOut && result.outputComplete) result.exitCode else -1
            }
        }.getOrDefault(-1)
    }

    private fun drainOutput(process: Process) {
        Thread({
            runCatching {
                process.inputStream.use { input ->
                    val buffer = ByteArray(4096)
                    while (input.read(buffer) >= 0) {
                        // Vendor output is intentionally discarded. Runtime secrets/config must
                        // not be projected into ordinary logs or UI.
                    }
                }
            }
        }, "mish-proxy-runtime-output").apply {
            isDaemon = true
            start()
        }
    }

    private fun terminateProcess(process: Process, pid: Int?): Boolean {
        process.destroy()
        return pid != null && stopExactRootSingBox(pid)
    }

    private fun cleanupCurrentLocked(): Boolean {
        stopping = true
        val currentChild = child
        val currentPid = childPid
        val currentBridge = bridge
        child = null
        childPid = null
        bridge = null
        servingCredentialVersion = null

        var clean = true
        if (currentChild != null && !terminateProcess(currentChild, currentPid)) clean = false
        if (currentBridge != null && runCatching { currentBridge.stop() }.isFailure) clean = false
        if (!deleteCurrentGenerationFiles(removeManifest = activeGenerationId != null)) clean = false
        stopping = false
        return clean
    }

    fun stop() {
        if (closed.get()) return
        try {
            executor.execute {
                val clean = synchronized(lock) { cleanupCurrentLocked() }
                if (clean) {
                    stopLifecycle()
                } else {
                    failLifecycle(RuntimeProcessFailure.CLEANUP_FAILED)
                }
            }
        } catch (_: RejectedExecutionException) {
            failLifecycle(RuntimeProcessFailure.CLEANUP_FAILED)
        }
    }

    private fun publishLifecycle() {
        mutableSnapshot.value = projectLifecycle(lifecycle.snapshot())
    }

    private fun failLifecycle(reason: RuntimeProcessFailure) {
        lifecycle.markFailed(reason)
        publishLifecycle()
    }

    private fun stopLifecycle() {
        lifecycle.markStopped()
        publishLifecycle()
    }

    private fun projectLifecycle(view: RuntimeProcessSnapshotView): ProxyRuntimeSnapshot =
        when (view.state) {
            RuntimeProcessState.STOPPED -> ProxyRuntimeSnapshot.Stopped
            RuntimeProcessState.STARTING -> ProxyRuntimeSnapshot.Starting
            RuntimeProcessState.RUNNING -> ProxyRuntimeSnapshot.Running
            RuntimeProcessState.FAILED -> ProxyRuntimeSnapshot.Failed(
                checkNotNull(view.failure) { "failed runtime process must carry a typed reason" },
            )
        }

    private fun deleteIfPresent(file: File): Boolean = !file.exists() || file.delete() || !file.exists()

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val cleanup = try {
            executor.submit(Callable {
                synchronized(lock) {
                    cleanupCurrentLocked()
                }
            })
        } catch (_: RejectedExecutionException) {
            null
        }
        val clean = try {
            cleanup?.get(CLOSE_TIMEOUT_SECONDS, TimeUnit.SECONDS) == true
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        } catch (_: Exception) {
            false
        }
        executor.shutdownNow()
        monitor?.interrupt()
        if (clean) {
            stopLifecycle()
        } else {
            failLifecycle(RuntimeProcessFailure.CLEANUP_FAILED)
        }
    }

    private companion object {
        const val RUNTIME_DIR = "proxy-runtime"
        const val LEGACY_CONFIG_FILE = "sing-box.json"
        const val LEGACY_PID_FILE = "sing-box.pid"
        const val LEGACY_ROOT_LAUNCHER_FILE = "sing-box-root-launch.sh"
        const val LEGACY_ROOT_CONTROL_FILE = "sing-box-root-control.sh"
        const val GENERATION_MANIFEST_FILE = "sing-box-current-generation"
        const val GENERATION_ID_LENGTH = 24
        const val SING_BOX_LIBRARY = "libsingbox.so"
        const val MAGISK_SU = "su"
        const val LOOPBACK = "127.0.0.1"
        const val OUTBOUND_TIMEOUT_MS = 15_000L
        const val START_HEALTH_TIMEOUT_SECONDS = 5L
        const val HEALTH_RETRY_MS = 100L
        const val HEALTH_POLL_MS = 500L
        const val HEALTH_CONNECT_TIMEOUT_MS = 250
        // DEVICE-1 Magisk may deliver a cold app-side `su` receipt after the child was forked.
        // This remains bounded; it is not a readiness retry or a generic root session.
        const val PID_RECORD_TIMEOUT_MS = 5_000L
        const val PID_RECORD_RETRY_MS = 25L
        const val CLOSE_TIMEOUT_SECONDS = 25L
        const val PRIVATE_FILE_MODE = 384 // 0600
        const val ROOT_SCRIPT_MODE = 448 // 0700
        const val ROOT_CONTROL_PROCESS_ABSENT = 20
        val SAFE_PATH = Regex("""/[A-Za-z0-9_./~=-]+""")
        val GENERATION_ID = Regex("""[A-Za-z0-9_-]{24}""")
        val ROOT_ACTIONS = setOf("status", "stop")
        val RECOVERABLE_UNEXPECTED_FAILURES = setOf(
            RuntimeProcessFailure.HEALTH_CHECK_FAILED,
            RuntimeProcessFailure.CHILD_EXITED,
            RuntimeProcessFailure.PRIVATE_BRIDGE_UNHEALTHY,
        )
    }
}

private const val CREDENTIAL_BYTES = 24
private val SECURE_RANDOM = SecureRandom()
