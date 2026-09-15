package com.mobileproxymish.app

import android.content.Context
import android.system.Os
import android.util.Base64
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.app.cellular.SuProcess
import com.mobileproxymish.ffi.CellularBridgeRuntime
import com.mobileproxymish.ffi.RuntimeCurrentProcessDecision
import com.mobileproxymish.ffi.RuntimeProcessFailure
import com.mobileproxymish.ffi.RuntimeProcessLifecycleController
import com.mobileproxymish.ffi.RuntimeProcessSnapshotView
import com.mobileproxymish.ffi.RuntimeProcessState
import com.mobileproxymish.ffi.proxyListenerPorts
import com.mobileproxymish.ffi.renderProxyRuntimeConfig
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
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

/** Non-secret read-only observation of the exact currently owned runtime generation. */
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
 * Android child-process effect adapter for the Rust Runtime Lifecycle and process reconciliation
 * natural owners. Android executes files/root/process effects; ownership decisions stay in Rust.
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
    private val processReconciler = ProxyProcessReconciler(runtimeDir)
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
            childAlive = ownedChildAccepted && childPid != null,
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

            // Process discovery is an Android/root observation. Ownership classification and the
            // terminate/clean/fail-closed decision are made by mish-runtime through UniFFI.
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

            if (!cellularRuntime.awaitAuthorizedAdmission(AUTHORIZED_ADMISSION_TIMEOUT_MS)) {
                deleteCurrentGenerationFiles(removeManifest = true)
                failLifecycle(RuntimeProcessFailure.PRIVATE_BRIDGE_UNAVAILABLE)
                return
            }

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

            ownedRootChildMayExist = true
            if (!runRootScript(rootLauncherFile)) {
                val clean = cleanupFailedStart(privateBridge = newBridge)
                failLifecycle(
                    if (clean) RuntimeProcessFailure.CHILD_PROCESS_START_FAILED
                    else RuntimeProcessFailure.CLEANUP_FAILED,
                )
                return
            }

            val (newPid, identityFailure) = awaitCurrentOwnedPid()
            if (newPid == null) {
                val clean = cleanupFailedStart(privateBridge = newBridge)
                failLifecycle(
                    if (clean) {
                        identityFailure ?: RuntimeProcessFailure.CHILD_PID_OR_PERSISTENCE_FAILED
                    } else {
                        RuntimeProcessFailure.CLEANUP_FAILED
                    },
                )
                return
            }

            val healthFailure = waitForHealthy(newBridge, newPid)
            if (healthFailure != null) {
                val clean = cleanupFailedStart(privateBridge = newBridge)
                failLifecycle(if (clean) healthFailure else RuntimeProcessFailure.CLEANUP_FAILED)
                return
            }

            if (closed.get()) {
                val clean = cleanupFailedStart(privateBridge = newBridge)
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
            var nextOwnershipCheck = 0L
            while (!closed.get()) {
                val now = System.nanoTime()
                val ownershipFailure = if (now >= nextOwnershipCheck) {
                    nextOwnershipCheck = now + TimeUnit.MILLISECONDS.toNanos(OWNERSHIP_POLL_MS)
                    currentProcessFailure(expectedPid)
                } else {
                    null
                }
                val reason = when {
                    ownershipFailure != null -> ownershipFailure
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
                        } else {
                            currentProcessFailure(expectedPid)
                                ?: RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE
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
            if (!first.exactChildAlive) {
                return currentProcessFailure(expectedPid)
                    ?: RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH
            }
            if (!first.privateBridgeHealthy) return RuntimeProcessFailure.PRIVATE_BRIDGE_UNHEALTHY
            if (!first.listenersReachable) {
                Thread.sleep(HEALTH_RETRY_MS)
                continue
            }

            Thread.sleep(START_OWNERSHIP_STABILITY_MS)
            val second = observeStartupHealth(privateBridge, expectedPid, publicPorts)
            if (!second.exactChildAlive) {
                return currentProcessFailure(expectedPid)
                    ?: RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH
            }
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
        exactChildAlive = currentProcessFailure(expectedPid) == null,
        privateBridgeHealthy = runCatching { privateBridge.isHealthy() }.getOrDefault(false),
        listenersReachable = publicPorts.all(::canConnectLoopback),
    )

    private fun currentProcessFailure(expectedPid: Int): RuntimeProcessFailure? {
        val resolution = processReconciler.resolveCurrentProcess(configFile)
            ?: return RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH
        return when (resolution.decision) {
            RuntimeCurrentProcessDecision.EXACT -> {
                val actual = resolution.current?.pid?.toLong()
                if (actual == expectedPid.toLong()) null
                else RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH
            }
            RuntimeCurrentProcessDecision.ABSENT -> RuntimeProcessFailure.CHILD_EXITED
            RuntimeCurrentProcessDecision.CONFLICT,
            RuntimeCurrentProcessDecision.FAIL_CLOSED,
            -> RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH
        }
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
        if (!isSafeOwnedPath(configFile) || !isSafeNativePath(binaryFile)) return false
        rootLauncherFile.writeText(
            """
            #!/system/bin/sh
            umask 077
            /system/bin/toybox nohup "${binaryFile.absolutePath}" run -c "${configFile.absolutePath}" </dev/null >/dev/null 2>&1 &
            exit 0
            """.trimIndent() + "\n",
            Charsets.UTF_8,
        )
        Os.chmod(rootLauncherFile.absolutePath, ROOT_SCRIPT_MODE)
        true
    } catch (_: Exception) {
        false
    }

    private fun cleanupOwnedOrphanProcesses(): Boolean = processReconciler.cleanupOwnedProcesses()

    private fun runRootScript(script: File): Boolean {
        if (!script.isFile || !isSafeOwnedPath(script)) return false
        return runCatching {
            SuProcess().run(listOf(MAGISK_SU, "-c", script.absolutePath)).let { result ->
                !result.timedOut && result.outputComplete && result.exitCode == 0
            }
        }.getOrDefault(false)
    }

    private fun isSafeOwnedPath(file: File): Boolean = file.absolutePath
        .let { it.startsWith(runtimeDir.absolutePath + "/") && SAFE_PATH.matches(it) }

    private fun isSafeNativePath(file: File): Boolean = file.absolutePath
        .let { it.startsWith(appContext.applicationInfo.nativeLibraryDir + "/") && SAFE_PATH.matches(it) }

    private fun awaitCurrentOwnedPid(): Pair<Int?, RuntimeProcessFailure?> {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(PID_RECORD_TIMEOUT_MS)
        var sawConflict = false
        while (System.nanoTime() < deadline) {
            val resolution = processReconciler.resolveCurrentProcess(configFile)
                ?: return null to RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH
            when (resolution.decision) {
                RuntimeCurrentProcessDecision.EXACT -> {
                    val rawPid = resolution.current?.pid?.toLong()
                        ?: return null to RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH
                    if (rawPid <= 0 || rawPid > Int.MAX_VALUE.toLong()) {
                        return null to RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH
                    }
                    val pid = rawPid.toInt()
                    if (!persistCanonicalPid(pid)) {
                        return null to RuntimeProcessFailure.CHILD_PID_OR_PERSISTENCE_FAILED
                    }
                    return pid to null
                }
                RuntimeCurrentProcessDecision.ABSENT -> Unit
                RuntimeCurrentProcessDecision.CONFLICT -> sawConflict = true
                RuntimeCurrentProcessDecision.FAIL_CLOSED ->
                    return null to RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH
            }
            Thread.sleep(PID_RECORD_RETRY_MS)
        }
        return null to if (sawConflict) {
            RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH
        } else {
            RuntimeProcessFailure.CHILD_PID_OR_PERSISTENCE_FAILED
        }
    }

    private fun persistCanonicalPid(pid: Int): Boolean = try {
        if (pid <= 0 || !isSafeOwnedPath(pidFile)) return false
        FileOutputStream(pidFile).use { output ->
            output.write("$pid\n".toByteArray(Charsets.US_ASCII))
            output.fd.sync()
        }
        Os.chmod(pidFile.absolutePath, PRIVATE_FILE_MODE)
        true
    } catch (_: Exception) {
        false
    }

    /** Rust-owned reconciliation proves all app-owned stale processes absent before identity reset. */
    private fun cleanupStaleChild(): Boolean = runCatching {
        if (!cleanupOwnedOrphanProcesses()) return@runCatching false
        deleteCurrentGenerationFiles(removeManifest = activeGenerationId != null)
    }.getOrDefault(false)

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
        privateBridge: CellularBridgeRuntime,
    ): Boolean {
        val terminationConfirmed = if (!ownedRootChildMayExist) {
            true
        } else {
            cleanupOwnedOrphanProcesses()
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

        val currentBridge = bridge
        val terminationConfirmed = if (!ownedRootChildMayExist) {
            true
        } else {
            cleanupOwnedOrphanProcesses()
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
        const val OWNERSHIP_POLL_MS = 3_000L
        const val HEALTH_CONNECT_TIMEOUT_MS = 250
        const val PID_RECORD_TIMEOUT_MS = 5_000L
        const val PID_RECORD_RETRY_MS = 50L
        const val CLOSE_TIMEOUT_SECONDS = 25L
        const val PRIVATE_FILE_MODE = 384 // 0600
        const val ROOT_SCRIPT_MODE = 448 // 0700
        val SAFE_PATH = Regex("""/[A-Za-z0-9_./~=-]+""")
        val GENERATION_ID = Regex("""[A-Za-z0-9_-]{24}""")
        val RECOVERABLE_UNEXPECTED_FAILURES = setOf(
            RuntimeProcessFailure.HEALTH_CHECK_FAILED,
            RuntimeProcessFailure.CHILD_EXITED,
            RuntimeProcessFailure.PRIVATE_BRIDGE_UNHEALTHY,
        )
    }
}

private const val CREDENTIAL_BYTES = 24
private val SECURE_RANDOM = SecureRandom()