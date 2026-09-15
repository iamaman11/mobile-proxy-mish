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

/** One bounded startup sample. Listener reachability alone is never enough for RUNNING. */
internal data class ProxyStartupHealthObservation(
    val exactChildAlive: Boolean,
    val privateBridgeHealthy: Boolean,
    val listenersReachable: Boolean,
)

/** RUNNING requires the same owned child to remain healthy across a short startup stability gap. */
internal fun stableStartupHealth(
    first: ProxyStartupHealthObservation,
    second: ProxyStartupHealthObservation,
): Boolean =
    first.exactChildAlive &&
        first.privateBridgeHealthy &&
        first.listenersReachable &&
        second.exactChildAlive &&
        second.privateBridgeHealthy &&
        second.listenersReachable

/** Never erase the only deterministic cleanup identity while a root child may still exist. */
internal fun generationIdentityMayBeDeleted(
    ownedChildMayExist: Boolean,
    terminationConfirmed: Boolean,
): Boolean = !ownedChildMayExist || terminationConfirmed

/**
 * Android child-process effect adapter for the Rust Runtime Lifecycle natural owner.
 *
 * canonical loopback sing-box listeners
 *   -> private loopback SOCKS bridge
 *   -> the exact Cellular Egress owner
 *
 * Files/Android PID effects remain here. STARTING/RUNNING/FAILED/STOPPED and failure reason state
 * are owned by `mish-runtime` and exposed through the typed UniFFI seam. All privileged runtime
 * launch/status/stop/cleanup commands reuse the process-wide persistent `SuProcess` session.
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
    private val ownedOrphanCleanupFile = File(runtimeDir, OWNED_ORPHAN_CLEANUP_FILE)
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

    private var childPid: Int? = null
    private var ownedRootChildMayExist = false
    private var ownedChildAccepted = false
    private var bridge: CellularBridgeRuntime? = null
    private var servingCredentialVersion: ULong? = null
    private var monitor: Thread? = null
    private var stopping = false

    val snapshot: StateFlow<ProxyRuntimeSnapshot>
        get() = mutableSnapshot.asStateFlow()

    internal fun diagnosticObservation(): ProxyRuntimeDiagnosticObservation = synchronized(lock) {
        val currentBridge = bridge
        ProxyRuntimeDiagnosticObservation(
            childAlive = ownedChildAccepted && childPid != null && canonicalLoopbackListenersReachable(),
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
            val generationId = activeGenerationId
            if (generationId == null) {
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

            // A private bridge opened before the asynchronously reconciled Cellular Egress
            // generation is authorized can fail its listener health check spuriously. This is a
            // dependency gate, not another readiness state: the cellular adapter's published
            // OwnerSnapshot remains the sole authority for admission and root-policy success.
            if (!cellularRuntime.awaitAuthorizedAdmission(AUTHORIZED_ADMISSION_TIMEOUT_MS)) {
                deleteCurrentGenerationFiles(removeManifest = true)
                failLifecycle(RuntimeProcessFailure.PRIVATE_BRIDGE_UNAVAILABLE)
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
            // Validate the exact generated config before root launch. Output is drained and
            // discarded because it may mention sensitive runtime paths or credentials; only the
            // bounded exit status influences lifecycle state.
            if (!validatePrivateConfig()) {
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

            // From this point the launch script may have forked a root child even if its bounded
            // receipt later fails. Keep generation identity until exact stop or exact app-owned
            // orphan cleanup proves the child absent.
            ownedRootChildMayExist = true
            if (!runRootScript(rootLauncherFile)) {
                val clean = cleanupFailedStart(pid = null, privateBridge = newBridge)
                failLifecycle(
                    if (clean) RuntimeProcessFailure.CHILD_PROCESS_START_FAILED
                    else RuntimeProcessFailure.CLEANUP_FAILED,
                )
                return
            }

            // The persistent root-shell receipt is not the runtime child identity. The PID file
            // written by the generation-scoped launch script remains the authoritative receipt.
            val newPid = awaitRecordedPid()
            if (newPid == null) {
                val clean = cleanupFailedStart(pid = null, privateBridge = newBridge)
                failLifecycle(
                    if (clean) RuntimeProcessFailure.CHILD_PID_OR_PERSISTENCE_FAILED
                    else RuntimeProcessFailure.CLEANUP_FAILED,
                )
                return
            }

            val healthFailure = waitForHealthy(newBridge, newPid)
            if (healthFailure != null) {
                val clean = cleanupFailedStart(pid = newPid, privateBridge = newBridge)
                failLifecycle(if (clean) healthFailure else RuntimeProcessFailure.CLEANUP_FAILED)
                return
            }

            // Keep the 0600 app-private config for the lifetime of the child. DEVICE-1 shows
            // that removing it immediately after the first accept can leave a live sing-box PID
            // with its listeners gone. Exact stop/failed-start cleanup removes this generation
            // file together with its PID/control records.

            if (closed.get()) {
                val clean = cleanupFailedStart(pid = newPid, privateBridge = newBridge)
                if (clean) stopLifecycle() else failLifecycle(RuntimeProcessFailure.CLEANUP_FAILED)
                return
            }

            childPid = newPid
            ownedChildAccepted = true
            bridge = newBridge
            servingCredentialVersion = publicCredential.version
            stopping = false
            check(lifecycle.markRunning()) { "proxy runtime left STARTING before health publication" }
            publishLifecycle()
            startMonitor(newPid, newBridge, generationId)
        }
    }

    private fun startMonitor(
        expectedPid: Int,
        expectedBridge: CellularBridgeRuntime,
        expectedGenerationId: String,
    ) {
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
                        } else if (isExactRootSingBoxAlive(expectedPid)) {
                            RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE
                        } else {
                            RuntimeProcessFailure.CHILD_EXITED
                        }
                    }
                }
                if (reason != null) {
                    try {
                        executor.execute {
                            synchronized(lock) {
                                if (
                                    !stopping &&
                                    childPid == expectedPid &&
                                    activeGenerationId == expectedGenerationId
                                ) {
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

    /** Returns a sanitized typed failure; config, credentials and process output stay private. */
    private fun waitForHealthy(
        privateBridge: CellularBridgeRuntime,
        expectedPid: Int,
    ): RuntimeProcessFailure? {
        val publicPorts = try {
            proxyListenerPorts().map { it.toInt() }
        } catch (_: LinkageError) {
            return RuntimeProcessFailure.LISTENER_CONTRACT_UNAVAILABLE
        } catch (_: Exception) {
            return RuntimeProcessFailure.LISTENER_CONTRACT_UNAVAILABLE
        }
        if (publicPorts.isEmpty()) return RuntimeProcessFailure.LISTENER_CONTRACT_UNAVAILABLE

        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(START_HEALTH_TIMEOUT_SECONDS)
        while (System.nanoTime() < deadline) {
            val first = observeStartupHealth(privateBridge, expectedPid, publicPorts)
            if (!first.exactChildAlive) return RuntimeProcessFailure.CHILD_EXITED
            if (!first.privateBridgeHealthy) return RuntimeProcessFailure.PRIVATE_BRIDGE_UNHEALTHY
            if (!first.listenersReachable) {
                Thread.sleep(HEALTH_RETRY_MS)
                continue
            }

            // A stale old listener can be reachable in the short interval while the newly forked
            // child is failing its own bind. Require the exact current PID to remain alive after
            // that interval before accepting the generation as RUNNING.
            Thread.sleep(START_OWNERSHIP_STABILITY_MS)
            val second = observeStartupHealth(privateBridge, expectedPid, publicPorts)
            if (!second.exactChildAlive) return RuntimeProcessFailure.CHILD_EXITED
            if (!second.privateBridgeHealthy) return RuntimeProcessFailure.PRIVATE_BRIDGE_UNHEALTHY
            if (stableStartupHealth(first, second)) return null
        }
        return RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE
    }

    private fun observeStartupHealth(
        privateBridge: CellularBridgeRuntime,
        expectedPid: Int,
        publicPorts: List<Int>,
    ): ProxyStartupHealthObservation = ProxyStartupHealthObservation(
        exactChildAlive = isExactRootSingBoxAlive(expectedPid),
        privateBridgeHealthy = runCatching { privateBridge.isHealthy() }.getOrDefault(false),
        listenersReachable = publicPorts.all(::canConnectLoopback),
    )

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

    private fun validatePrivateConfig(): Boolean = try {
        val checker = ProcessBuilder(
            binaryFile.absolutePath,
            "check",
            "-c",
            configFile.absolutePath,
        )
            .directory(runtimeDir)
            .redirectErrorStream(true)
            .start()
        drainOutput(checker)
        if (!checker.waitFor(CONFIG_CHECK_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            checker.destroyForcibly()
            return false
        }
        checker.exitValue() == 0
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

    private fun writeOwnedOrphanCleanup(): Boolean = try {
        if (
            !SAFE_PATH.matches(runtimeDir.absolutePath) ||
            !isSafeOwnedPath(ownedOrphanCleanupFile)
        ) return false

        // The app-private noBackup runtime path is stable across replacement APK versions while
        // nativeLibraryDir may change. Matching exact argv shape + that private config path safely
        // catches an orphan created by an older APK without broad process-name killing.
        ownedOrphanCleanupFile.writeText(
            """
            #!/system/bin/sh
            set -eu
            runtime="${runtimeDir.absolutePath}"
            pids=""
            for proc in /proc/[0-9]*; do
              [ -r "${'$'}proc/cmdline" ] || continue
              actual="${'$'}(tr '\000' ' ' < "${'$'}proc/cmdline" 2>/dev/null || true)"
              case "${'$'}actual" in
                *"/${SING_BOX_LIBRARY} run -c ${'$'}runtime/sing-box-"*.json\ |*"/${SING_BOX_LIBRARY} run -c ${'$'}runtime/${LEGACY_CONFIG_FILE} ")
                  pid="${'$'}{proc#/proc/}"
                  case "${'$'}pid" in ''|*[!0-9]*) exit 64;; esac
                  kill -TERM "${'$'}pid" 2>/dev/null || true
                  pids="${'$'}pids ${'$'}pid"
                  ;;
              esac
            done
            [ -z "${'$'}pids" ] && exit 0
            i=0
            while [ "${'$'}i" -lt 60 ]; do
              alive=0
              for pid in ${'$'}pids; do [ -d "/proc/${'$'}pid" ] && alive=1; done
              [ "${'$'}alive" -eq 0 ] && exit 0
              sleep 0.05
              i=${'$'}((i + 1))
            done
            for pid in ${'$'}pids; do
              [ -d "/proc/${'$'}pid" ] && kill -KILL "${'$'}pid" 2>/dev/null || true
            done
            i=0
            while [ "${'$'}i" -lt 40 ]; do
              alive=0
              for pid in ${'$'}pids; do [ -d "/proc/${'$'}pid" ] && alive=1; done
              [ "${'$'}alive" -eq 0 ] && exit 0
              sleep 0.05
              i=${'$'}((i + 1))
            done
            exit 5
            """.trimIndent() + "\n",
            Charsets.UTF_8,
        )
        Os.chmod(ownedOrphanCleanupFile.absolutePath, ROOT_SCRIPT_MODE)
        true
    } catch (_: Exception) {
        false
    }

    private fun cleanupOwnedOrphanProcesses(): Boolean {
        if (!writeOwnedOrphanCleanup()) return false
        val cleaned = runRootScript(ownedOrphanCleanupFile)
        val scriptDeleted = deleteIfPresent(ownedOrphanCleanupFile)
        return cleaned && scriptDeleted
    }

    private fun runRootScript(script: File): Boolean {
        if (!script.isFile || !isSafeOwnedPath(script)) return false
        return runCatching {
            SuProcess().run(listOf(MAGISK_SU, "-c", script.absolutePath)).let { result ->
                !result.timedOut && result.outputComplete && result.exitCode == 0
            }
        }.getOrDefault(false)
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

    /**
     * Startup reconciliation first uses any exact recorded PID, then performs one bounded scan for
     * app-owned orphan command lines. Generation files are deleted only after that scan proves no
     * such root child remains. This also repairs old orphans whose PID identity was already lost.
     */
    private fun cleanupStaleChild(): Boolean = runCatching {
        val recordedPid = if (pidFile.isFile) {
            pidFile.readText(Charsets.US_ASCII).trim().toIntOrNull()?.takeIf { it > 0 }
        } else {
            null
        }
        if (
            recordedPid != null &&
            isExactRootSingBoxAlive(recordedPid) &&
            !stopExactRootSingBox(recordedPid)
        ) {
            return@runCatching false
        }
        if (!cleanupOwnedOrphanProcesses()) return@runCatching false
        deleteCurrentGenerationFiles(removeManifest = activeGenerationId != null)
    }.getOrDefault(false)

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

    private fun cleanupFailedStart(
        pid: Int?,
        privateBridge: CellularBridgeRuntime,
    ): Boolean {
        val terminationConfirmed = if (!ownedRootChildMayExist) {
            true
        } else {
            (pid != null && stopExactRootSingBox(pid)) || cleanupOwnedOrphanProcesses()
        }
        if (terminationConfirmed) ownedRootChildMayExist = false
        ownedChildAccepted = false

        val bridgeStopped = runCatching { privateBridge.stop() }.isSuccess
        val identityDeleted = if (
            generationIdentityMayBeDeleted(ownedRootChildMayExist, terminationConfirmed)
        ) {
            deleteCurrentGenerationFiles(removeManifest = activeGenerationId != null)
        } else {
            false
        }
        return terminationConfirmed && bridgeStopped && identityDeleted
    }

    private fun cleanupCurrentLocked(): Boolean {
        stopping = true
        ownedChildAccepted = false
        servingCredentialVersion = null

        val currentPid = childPid
        val currentBridge = bridge
        val terminationConfirmed = if (!ownedRootChildMayExist) {
            true
        } else {
            (currentPid != null && stopExactRootSingBox(currentPid)) || cleanupOwnedOrphanProcesses()
        }
        if (terminationConfirmed) {
            ownedRootChildMayExist = false
            childPid = null
        }

        val bridgeStopped = if (currentBridge == null) {
            true
        } else {
            runCatching { currentBridge.stop() }.isSuccess
        }
        if (bridgeStopped) bridge = null

        val identityDeleted = if (
            generationIdentityMayBeDeleted(ownedRootChildMayExist, terminationConfirmed)
        ) {
            deleteCurrentGenerationFiles(removeManifest = activeGenerationId != null)
        } else {
            false
        }
        stopping = false
        return terminationConfirmed && bridgeStopped && identityDeleted
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
        const val OWNED_ORPHAN_CLEANUP_FILE = "sing-box-owned-cleanup.sh"
        const val GENERATION_ID_LENGTH = 24
        const val SING_BOX_LIBRARY = "libsingbox.so"
        const val MAGISK_SU = "su"
        const val LOOPBACK = "127.0.0.1"
        const val OUTBOUND_TIMEOUT_MS = 15_000L
        const val AUTHORIZED_ADMISSION_TIMEOUT_MS = 30_000L
        const val CONFIG_CHECK_TIMEOUT_MS = 5_000L
        const val START_HEALTH_TIMEOUT_SECONDS = 5L
        const val START_OWNERSHIP_STABILITY_MS = 500L
        const val HEALTH_RETRY_MS = 100L
        const val HEALTH_POLL_MS = 500L
        const val HEALTH_CONNECT_TIMEOUT_MS = 250
        // DEVICE-1 Magisk may deliver a cold persistent root-shell command after the child fork.
        // PID capture remains bounded; normal runtime recovery reuses that one privilege session.
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
