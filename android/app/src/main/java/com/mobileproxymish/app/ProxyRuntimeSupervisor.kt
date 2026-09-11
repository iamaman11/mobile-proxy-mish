package com.mobileproxymish.app

import android.content.Context
import android.os.Process as AndroidProcess
import android.system.Os
import android.util.Base64
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.ffi.CellularBridgeRuntime
import com.mobileproxymish.ffi.renderProxyRuntimeConfig
import java.io.Closeable
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Runtime Lifecycle projection only; it does not own proxy protocol or cellular facts. */
sealed interface ProxyRuntimeSnapshot {
    data object Stopped : ProxyRuntimeSnapshot
    data object Starting : ProxyRuntimeSnapshot
    data object Running : ProxyRuntimeSnapshot

    data class Failed(
        val reason: ProxyRuntimeFailure,
    ) : ProxyRuntimeSnapshot
}

enum class ProxyRuntimeFailure {
    NativeRuntimeMissing,
    StaleProcessIdentityMismatch,
    PrivateBridgeUnavailable,
    ConfigurationRejected,
    ChildLaunchFailed,
    HealthCheckFailed,
    ChildExited,
    PrivateBridgeUnhealthy,
    CleanupFailed,
}

/**
 * Small Android composition owner for the already-approved runtime pieces:
 *
 * loopback sing-box (:1080/:1081/:3128)
 *   -> private loopback SOCKS bridge
 *   -> the exact Cellular Egress owner
 *
 * The public protocol/auth contract remains owned by `mish-proxy` + sing-box adapter. This
 * class owns only process-generation start/health/stop/reconciliation. It deliberately binds
 * loopback until the separate Mesh-ingress stage supplies an accepted non-wildcard address.
 */
class ProxyRuntimeSupervisor(
    context: Context,
    private val cellularRuntime: CellularRuntimeBridge,
) : Closeable {
    private val appContext = context.applicationContext
    private val runtimeDir = File(appContext.noBackupFilesDir, RUNTIME_DIR)
    private val configFile = File(runtimeDir, CONFIG_FILE)
    private val pidFile = File(runtimeDir, PID_FILE)
    private val binaryFile = File(appContext.applicationInfo.nativeLibraryDir, SING_BOX_LIBRARY)
    private val mutableSnapshot = MutableStateFlow<ProxyRuntimeSnapshot>(ProxyRuntimeSnapshot.Stopped)
    private val startRequested = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val lock = Any()
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-proxy-runtime").apply { isDaemon = true }
    }

    private var child: Process? = null
    private var childPid: Int? = null
    private var bridge: CellularBridgeRuntime? = null
    private var monitor: Thread? = null
    private var stopping = false

    val snapshot: StateFlow<ProxyRuntimeSnapshot>
        get() = mutableSnapshot.asStateFlow()

    fun start() {
        if (closed.get() || !startRequested.compareAndSet(false, true)) return
        mutableSnapshot.value = ProxyRuntimeSnapshot.Starting
        try {
            executor.execute(::startBlocking)
        } catch (_: RejectedExecutionException) {
            mutableSnapshot.value = ProxyRuntimeSnapshot.Failed(ProxyRuntimeFailure.ChildLaunchFailed)
        }
    }

    private fun startBlocking() {
        synchronized(lock) {
            if (closed.get()) return
            runtimeDir.mkdirs()
            if (!binaryFile.isFile || !binaryFile.canExecute()) {
                mutableSnapshot.value = ProxyRuntimeSnapshot.Failed(
                    ProxyRuntimeFailure.NativeRuntimeMissing,
                )
                return
            }
            if (!cleanupStaleChild()) {
                mutableSnapshot.value = ProxyRuntimeSnapshot.Failed(
                    ProxyRuntimeFailure.StaleProcessIdentityMismatch,
                )
                return
            }

            val privateUsername = randomCredential()
            val privatePassword = randomCredential()
            val publicUsername = randomCredential()
            val publicPassword = randomCredential()

            val newBridge = try {
                cellularRuntime.startPrivateBridge(
                    username = privateUsername,
                    password = privatePassword,
                    operationTimeoutMs = OUTBOUND_TIMEOUT_MS.toULong(),
                )
            } catch (_: Exception) {
                mutableSnapshot.value = ProxyRuntimeSnapshot.Failed(
                    ProxyRuntimeFailure.PrivateBridgeUnavailable,
                )
                return
            }

            val config = try {
                renderProxyRuntimeConfig(
                    listenAddress = LOOPBACK,
                    publicUsername = publicUsername,
                    publicPassword = publicPassword,
                    bridgePort = newBridge.port(),
                    bridgeUsername = privateUsername,
                    bridgePassword = privatePassword,
                )
            } catch (_: Exception) {
                runCatching { newBridge.stop() }
                mutableSnapshot.value = ProxyRuntimeSnapshot.Failed(
                    ProxyRuntimeFailure.ConfigurationRejected,
                )
                return
            }

            if (!writePrivateConfig(config)) {
                runCatching { newBridge.stop() }
                mutableSnapshot.value = ProxyRuntimeSnapshot.Failed(
                    ProxyRuntimeFailure.ConfigurationRejected,
                )
                return
            }

            val newChild = try {
                ProcessBuilder(
                    binaryFile.absolutePath,
                    "run",
                    "-c",
                    configFile.absolutePath,
                )
                    .directory(runtimeDir)
                    .redirectErrorStream(true)
                    .start()
            } catch (_: Exception) {
                configFile.delete()
                runCatching { newBridge.stop() }
                mutableSnapshot.value = ProxyRuntimeSnapshot.Failed(
                    ProxyRuntimeFailure.ChildLaunchFailed,
                )
                return
            }

            val newPid = processPid(newChild)
            if (newPid == null || !writePid(newPid)) {
                terminateProcess(newChild, newPid)
                configFile.delete()
                runCatching { newBridge.stop() }
                mutableSnapshot.value = ProxyRuntimeSnapshot.Failed(
                    ProxyRuntimeFailure.ChildLaunchFailed,
                )
                return
            }
            drainOutput(newChild)

            if (!waitForHealthy(newChild, newBridge)) {
                terminateProcess(newChild, newPid)
                pidFile.delete()
                configFile.delete()
                runCatching { newBridge.stop() }
                mutableSnapshot.value = ProxyRuntimeSnapshot.Failed(
                    ProxyRuntimeFailure.HealthCheckFailed,
                )
                return
            }

            // sing-box has consumed the configuration; remove runtime credential material from disk.
            configFile.delete()
            child = newChild
            childPid = newPid
            bridge = newBridge
            stopping = false
            mutableSnapshot.value = ProxyRuntimeSnapshot.Running
            startMonitor(newChild, newBridge)
        }
    }

    private fun startMonitor(expectedChild: Process, expectedBridge: CellularBridgeRuntime) {
        val thread = Thread({
            while (!closed.get()) {
                val reason = when {
                    !isAlive(expectedChild) -> ProxyRuntimeFailure.ChildExited
                    !runCatching { expectedBridge.isHealthy() }.getOrDefault(false) ->
                        ProxyRuntimeFailure.PrivateBridgeUnhealthy
                    else -> null
                }
                if (reason != null) {
                    synchronized(lock) {
                        if (!stopping && child === expectedChild) {
                            val cleanupOk = cleanupCurrentLocked()
                            mutableSnapshot.value = ProxyRuntimeSnapshot.Failed(
                                if (cleanupOk) reason else ProxyRuntimeFailure.CleanupFailed,
                            )
                        }
                    }
                    return@Thread
                }
                Thread.sleep(HEALTH_POLL_MS)
            }
        }, "mish-proxy-runtime-monitor")
        thread.isDaemon = true
        monitor = thread
        thread.start()
    }

    private fun waitForHealthy(
        process: Process,
        privateBridge: CellularBridgeRuntime,
    ): Boolean {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(START_HEALTH_TIMEOUT_SECONDS)
        while (System.nanoTime() < deadline) {
            if (!isAlive(process) || !runCatching { privateBridge.isHealthy() }.getOrDefault(false)) {
                return false
            }
            if (PUBLIC_PORTS.all(::canConnectLoopback)) return true
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

    private fun writePid(pid: Int): Boolean = try {
        pidFile.writeText(pid.toString(), Charsets.US_ASCII)
        Os.chmod(pidFile.absolutePath, PRIVATE_FILE_MODE)
        true
    } catch (_: Exception) {
        false
    }

    private fun cleanupStaleChild(): Boolean {
        configFile.delete()
        if (!pidFile.isFile) return true
        val pid = pidFile.readText(Charsets.US_ASCII).trim().toIntOrNull() ?: return false
        val procDir = File("/proc/$pid")
        if (!procDir.exists()) {
            pidFile.delete()
            return true
        }
        if (!isExactOwnedSingBoxProcess(pid)) return false
        AndroidProcess.killProcess(pid)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(STALE_KILL_TIMEOUT_SECONDS)
        while (procDir.exists() && System.nanoTime() < deadline) {
            Thread.sleep(25)
        }
        if (procDir.exists()) return false
        pidFile.delete()
        return true
    }

    private fun isExactOwnedSingBoxProcess(pid: Int): Boolean {
        return try {
            val status = File("/proc/$pid/status").readLines()
            val uid = status.firstOrNull { it.startsWith("Uid:") }
                ?.substringAfter("Uid:")
                ?.trim()
                ?.split(Regex("""\s+"""))
                ?.firstOrNull()
                ?.toIntOrNull()
            if (uid != AndroidProcess.myUid()) {
                false
            } else {
                val command = File("/proc/$pid/cmdline")
                    .readBytes()
                    .toString(Charsets.UTF_8)
                    .replace('\u0000', ' ')
                command.contains(SING_BOX_LIBRARY) && command.contains(configFile.absolutePath)
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun processPid(process: Process): Int? = try {
        val method = Process::class.java.getMethod("pid")
        (method.invoke(process) as Long).toInt().takeIf { it > 0 }
    } catch (_: Exception) {
        null
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

    private fun isAlive(process: Process): Boolean = try {
        process.exitValue()
        false
    } catch (_: IllegalThreadStateException) {
        true
    }

    private fun terminateProcess(process: Process, pid: Int?): Boolean {
        process.destroy()
        val gracefulDeadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(GRACEFUL_STOP_MS)
        while (isAlive(process) && System.nanoTime() < gracefulDeadline) {
            Thread.sleep(25)
        }
        if (!isAlive(process)) return true
        if (pid == null || !isExactOwnedSingBoxProcess(pid)) return false
        AndroidProcess.killProcess(pid)
        val forcedDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(FORCED_STOP_TIMEOUT_SECONDS)
        while (isAlive(process) && System.nanoTime() < forcedDeadline) {
            Thread.sleep(25)
        }
        return !isAlive(process)
    }

    private fun cleanupCurrentLocked(): Boolean {
        stopping = true
        val currentChild = child
        val currentPid = childPid
        val currentBridge = bridge
        child = null
        childPid = null
        bridge = null

        var clean = true
        if (currentChild != null && !terminateProcess(currentChild, currentPid)) clean = false
        if (currentBridge != null && runCatching { currentBridge.stop() }.isFailure) clean = false
        configFile.delete()
        pidFile.delete()
        stopping = false
        return clean
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val cleanup = try {
            executor.submit {
                synchronized(lock) {
                    cleanupCurrentLocked()
                }
            }
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
        mutableSnapshot.value = if (clean) {
            ProxyRuntimeSnapshot.Stopped
        } else {
            ProxyRuntimeSnapshot.Failed(ProxyRuntimeFailure.CleanupFailed)
        }
    }

    private fun randomCredential(): String {
        val bytes = ByteArray(CREDENTIAL_BYTES)
        SECURE_RANDOM.nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private companion object {
        const val RUNTIME_DIR = "proxy-runtime"
        const val CONFIG_FILE = "sing-box.json"
        const val PID_FILE = "sing-box.pid"
        const val SING_BOX_LIBRARY = "libsingbox.so"
        const val LOOPBACK = "127.0.0.1"
        const val OUTBOUND_TIMEOUT_MS = 15_000L
        const val START_HEALTH_TIMEOUT_SECONDS = 5L
        const val HEALTH_RETRY_MS = 100L
        const val HEALTH_POLL_MS = 500L
        const val HEALTH_CONNECT_TIMEOUT_MS = 250
        const val GRACEFUL_STOP_MS = 1_500L
        const val FORCED_STOP_TIMEOUT_SECONDS = 2L
        const val STALE_KILL_TIMEOUT_SECONDS = 2L
        const val CLOSE_TIMEOUT_SECONDS = 10L
        const val CREDENTIAL_BYTES = 24
        const val PRIVATE_FILE_MODE = 384 // 0600
        val PUBLIC_PORTS = listOf(1080, 1081, 3128)
        val SECURE_RANDOM = SecureRandom()
    }
}
