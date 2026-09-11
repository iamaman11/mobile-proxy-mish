package com.mobileproxymish.app.cellular

/** Desired kernel realization projected from the Cellular Egress natural owner. */
sealed interface RootPolicyIntent {
    data class Admitted(
        val generation: Long,
        val interfaceName: String,
    ) : RootPolicyIntent

    data class FailClosed(
        val reason: RootPolicyFailClosedReason,
    ) : RootPolicyIntent
}

enum class RootPolicyFailClosedReason {
    Startup,
    NoAdmittedNetwork,
    MissingInterface,
    RouteDiscoveryFailed,
    PolicyMutationFailed,
    PolicyVerificationFailed,
    OwnerBoundaryUnavailable,
}

/** Adapter execution projection only; this is not a second cellular-policy owner. */
sealed interface RootPolicyStatus {
    data object NotReconciled : RootPolicyStatus

    data class Active(
        val generation: Long,
        val interfaceName: String,
        val routingTable: String,
    ) : RootPolicyStatus

    data class FailClosed(
        val reason: RootPolicyFailClosedReason,
    ) : RootPolicyStatus

    data class Unavailable(
        val reason: RootPolicyFailureReason,
    ) : RootPolicyStatus
}

enum class RootPolicyFailureReason {
    InvalidProductUid,
    RootGrantRequired,
    RootDenied,
    RootUnavailable,
    RootIncomplete,
    KernelMutationFailed,
    KernelVerificationFailed,
}

enum class RootPolicyCleanupStatus {
    Cleaned,
    RootUnavailable,
    Failed,
}

/**
 * Bounded PRODUCT-owned root-policy reconciler.
 *
 * The executor does not decide whether cellular is admitted and never chooses a network.
 * It realizes one owner-projected intent using an allowlisted kernel adapter. When an
 * admitted table cannot be discovered/verified, the same PRODUCT mark remains guarded by
 * an RPDB unreachable rule, so marked NEW flows cannot fall through to default/WARP/Wi-Fi.
 */
class RootPolicyExecutor private constructor(
    private val platform: RootPolicyPlatform,
) {
    constructor() : this(ShellRootPolicyPlatform(SuProcess()))

    @Synchronized
    fun reconcile(productUid: Int, intent: RootPolicyIntent): RootPolicyStatus {
        if (productUid <= 0) {
            return RootPolicyStatus.Unavailable(RootPolicyFailureReason.InvalidProductUid)
        }

        val authorityFailure = mapAuthorityFailure(platform.authorityStatus())
        if (authorityFailure != null) {
            return RootPolicyStatus.Unavailable(authorityFailure)
        }

        // The unreachable guard is always established before the selector or any lookup
        // change. Thus a generation/table transition can only create a fail-closed gap.
        if (!platform.ensureGuard()) {
            return RootPolicyStatus.Unavailable(RootPolicyFailureReason.KernelMutationFailed)
        }
        if (!platform.ensureSelector(productUid)) {
            return RootPolicyStatus.Unavailable(RootPolicyFailureReason.KernelMutationFailed)
        }
        if (!platform.removeLookup()) {
            return RootPolicyStatus.FailClosed(RootPolicyFailClosedReason.PolicyMutationFailed)
        }

        return when (intent) {
            is RootPolicyIntent.FailClosed -> {
                if (platform.verifyFailClosed(productUid)) {
                    RootPolicyStatus.FailClosed(intent.reason)
                } else {
                    RootPolicyStatus.Unavailable(RootPolicyFailureReason.KernelVerificationFailed)
                }
            }

            is RootPolicyIntent.Admitted -> reconcileAdmitted(productUid, intent)
        }
    }

    /** Explicit maintenance cleanup; ordinary cellular loss uses FailClosed instead. */
    @Synchronized
    fun cleanup(productUid: Int): RootPolicyCleanupStatus {
        if (productUid <= 0 || platform.authorityStatus() != RootAuthorityStatus.Ready) {
            return RootPolicyCleanupStatus.RootUnavailable
        }
        return if (platform.cleanup(productUid)) {
            RootPolicyCleanupStatus.Cleaned
        } else {
            RootPolicyCleanupStatus.Failed
        }
    }

    private fun reconcileAdmitted(
        productUid: Int,
        intent: RootPolicyIntent.Admitted,
    ): RootPolicyStatus {
        if (!RootPolicyParsers.validInterfaceName(intent.interfaceName)) {
            return RootPolicyStatus.FailClosed(RootPolicyFailClosedReason.MissingInterface)
        }

        val table = platform.discoverValidatedTable(intent.interfaceName)
            ?: return RootPolicyStatus.FailClosed(RootPolicyFailClosedReason.RouteDiscoveryFailed)

        if (!platform.installLookup(table)) {
            platform.removeLookup()
            return RootPolicyStatus.FailClosed(RootPolicyFailClosedReason.PolicyMutationFailed)
        }

        if (!platform.verifyActive(productUid, intent.interfaceName, table)) {
            // Lookup is removed before returning so a verification failure cannot leave a
            // possibly stale cellular route in front of the unreachable guard.
            platform.removeLookup()
            return if (platform.verifyFailClosed(productUid)) {
                RootPolicyStatus.FailClosed(RootPolicyFailClosedReason.PolicyVerificationFailed)
            } else {
                RootPolicyStatus.Unavailable(RootPolicyFailureReason.KernelVerificationFailed)
            }
        }

        return RootPolicyStatus.Active(
            generation = intent.generation,
            interfaceName = intent.interfaceName,
            routingTable = table,
        )
    }

    private fun mapAuthorityFailure(status: RootAuthorityStatus): RootPolicyFailureReason? =
        when (status) {
            RootAuthorityStatus.Ready -> null
            RootAuthorityStatus.InteractiveGrantRequired -> RootPolicyFailureReason.RootGrantRequired
            RootAuthorityStatus.Denied -> RootPolicyFailureReason.RootDenied
            RootAuthorityStatus.Unavailable -> RootPolicyFailureReason.RootUnavailable
            RootAuthorityStatus.Incomplete -> RootPolicyFailureReason.RootIncomplete
        }

    internal companion object {
        fun forTesting(platform: RootPolicyPlatform): RootPolicyExecutor = RootPolicyExecutor(platform)
    }
}

/** Test seam and platform adapter boundary; callers cannot pass arbitrary shell commands. */
internal interface RootPolicyPlatform {
    fun authorityStatus(): RootAuthorityStatus
    fun ensureGuard(): Boolean
    fun ensureSelector(productUid: Int): Boolean
    fun removeLookup(): Boolean
    fun discoverValidatedTable(interfaceName: String): String?
    fun installLookup(table: String): Boolean
    fun verifyActive(productUid: Int, interfaceName: String, table: String): Boolean
    fun verifyFailClosed(productUid: Int): Boolean
    fun cleanup(productUid: Int): Boolean
}

/** Magisk/iproute2/iptables realization of the bounded platform operations. */
internal class ShellRootPolicyPlatform(
    private val process: RootProcess,
) : RootPolicyPlatform {
    private val authority = MagiskRootAuthority.forTesting(process)

    override fun authorityStatus(): RootAuthorityStatus = authority.probe()

    override fun ensureGuard(): Boolean {
        val current = root("ip -4 rule show")
        if (!current.ok()) return false
        if (RootPolicyParsers.hasGuard(current.stdout)) return true

        return root(
            "ip -4 rule add priority $GUARD_PRIORITY fwmark $MARK/$MASK unreachable",
        ).ok()
    }

    override fun ensureSelector(productUid: Int): Boolean {
        if (selectorPresent(productUid) && ipv6GuardPresent(productUid)) {
            return true
        }

        val ipv4 = root(
            "set -e; " +
                "iptables -w 2 -t mangle -N $IPV4_CHAIN 2>/dev/null || true; " +
                "while iptables -w 2 -t mangle -D OUTPUT -j $IPV4_CHAIN 2>/dev/null; do :; done; " +
                "iptables -w 2 -t mangle -F $IPV4_CHAIN; " +
                "iptables -w 2 -t mangle -A $IPV4_CHAIN -o lo -j RETURN; " +
                "iptables -w 2 -t mangle -A $IPV4_CHAIN -m owner --uid-owner $productUid " +
                "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK/$MASK; " +
                "iptables -w 2 -t mangle -I OUTPUT 1 -j $IPV4_CHAIN",
        )
        if (!ipv4.ok()) return false

        // IPv6 is intentionally fail-closed until separate physical carrier evidence exists.
        val ipv6 = root(
            "set -e; " +
                "ip6tables -w 2 -t filter -N $IPV6_CHAIN 2>/dev/null || true; " +
                "while ip6tables -w 2 -t filter -D OUTPUT -j $IPV6_CHAIN 2>/dev/null; do :; done; " +
                "ip6tables -w 2 -t filter -F $IPV6_CHAIN; " +
                "ip6tables -w 2 -t filter -A $IPV6_CHAIN -o lo -j RETURN; " +
                "ip6tables -w 2 -t filter -A $IPV6_CHAIN -m owner --uid-owner $productUid " +
                "-m conntrack --ctstate NEW -j DROP; " +
                "ip6tables -w 2 -t filter -I OUTPUT 1 -j $IPV6_CHAIN",
        )
        return ipv6.ok() && selectorPresent(productUid) && ipv6GuardPresent(productUid)
    }

    override fun removeLookup(): Boolean = root(
        "set -e; " +
            "while ip -4 rule del priority $LOOKUP_PRIORITY fwmark $MARK/$MASK 2>/dev/null; " +
            "do :; done; :",
    ).ok()

    override fun discoverValidatedTable(interfaceName: String): String? {
        if (!RootPolicyParsers.validInterfaceName(interfaceName)) return null

        val allRoutes = root("ip -4 route show table all dev $interfaceName")
        if (!allRoutes.ok()) return null
        val table = RootPolicyParsers.discoverUniqueCellularTable(allRoutes.stdout, interfaceName)
            ?: return null
        if (!RootPolicyParsers.validTableName(table)) return null

        val tableRoutes = root("ip -4 route show table $table")
        if (!tableRoutes.ok()) return null
        return table.takeIf {
            RootPolicyParsers.hasDefaultRouteOnInterface(tableRoutes.stdout, interfaceName)
        }
    }

    override fun installLookup(table: String): Boolean {
        if (!RootPolicyParsers.validTableName(table)) return false
        return root(
            "ip -4 rule add priority $LOOKUP_PRIORITY fwmark $MARK/$MASK lookup $table",
        ).ok()
    }

    override fun verifyActive(productUid: Int, interfaceName: String, table: String): Boolean {
        val rules = root("ip -4 rule show")
        if (!rules.ok()) return false
        if (!RootPolicyParsers.hasGuard(rules.stdout)) return false
        if (!RootPolicyParsers.hasLookup(rules.stdout, table)) return false
        if (!selectorPresent(productUid) || !ipv6GuardPresent(productUid)) return false

        val route = root("ip -4 route get 1.1.1.1 mark $MARK")
        return route.ok() && RootPolicyParsers.routeUsesInterface(route.stdout, interfaceName)
    }

    override fun verifyFailClosed(productUid: Int): Boolean {
        val rules = root("ip -4 rule show")
        return rules.ok() &&
            RootPolicyParsers.hasGuard(rules.stdout) &&
            !RootPolicyParsers.hasAnyOwnedLookup(rules.stdout) &&
            selectorPresent(productUid) &&
            ipv6GuardPresent(productUid)
    }

    override fun cleanup(productUid: Int): Boolean {
        // Stop creating new PRODUCT marks first, then remove only exact PRODUCT-owned
        // chains/rules. This method is explicit maintenance cleanup, not loss handling.
        val selectors = root(
            "set -e; " +
                "while iptables -w 2 -t mangle -D OUTPUT -j $IPV4_CHAIN 2>/dev/null; do :; done; " +
                "iptables -w 2 -t mangle -F $IPV4_CHAIN 2>/dev/null || true; " +
                "iptables -w 2 -t mangle -X $IPV4_CHAIN 2>/dev/null || true; " +
                "while ip6tables -w 2 -t filter -D OUTPUT -j $IPV6_CHAIN 2>/dev/null; do :; done; " +
                "ip6tables -w 2 -t filter -F $IPV6_CHAIN 2>/dev/null || true; " +
                "ip6tables -w 2 -t filter -X $IPV6_CHAIN 2>/dev/null || true; :",
        )
        if (!selectors.ok()) return false
        if (!removeLookup()) return false
        val guard = root(
            "set -e; " +
                "while ip -4 rule del priority $GUARD_PRIORITY fwmark $MARK/$MASK 2>/dev/null; " +
                "do :; done; :",
        )
        if (!guard.ok()) return false

        val rules = root("ip -4 rule show")
        return rules.ok() &&
            !RootPolicyParsers.hasGuard(rules.stdout) &&
            !RootPolicyParsers.hasAnyOwnedLookup(rules.stdout) &&
            !selectorPresent(productUid) &&
            !ipv6GuardPresent(productUid)
    }

    private fun selectorPresent(productUid: Int): Boolean =
        root("iptables -w 2 -t mangle -C OUTPUT -j $IPV4_CHAIN").ok() &&
            root(
                "iptables -w 2 -t mangle -C $IPV4_CHAIN -m owner --uid-owner $productUid " +
                    "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK/$MASK",
            ).ok()

    private fun ipv6GuardPresent(productUid: Int): Boolean =
        root("ip6tables -w 2 -t filter -C OUTPUT -j $IPV6_CHAIN").ok() &&
            root(
                "ip6tables -w 2 -t filter -C $IPV6_CHAIN -m owner --uid-owner $productUid " +
                    "-m conntrack --ctstate NEW -j DROP",
            ).ok()

    private fun root(command: String): RootProcessResult =
        process.run(listOf("su", "-c", command))

    private fun RootProcessResult.ok(): Boolean = !timedOut && exitCode == 0
}

/** Pure parsers for bounded route/RPDB output; no live facts are persisted here. */
internal object RootPolicyParsers {
    private val interfacePattern = Regex("[A-Za-z0-9_.-]{1,32}")
    private val tablePattern = Regex("[A-Za-z0-9_.-]{1,32}")
    private val forbiddenTables = setOf("local", "main", "default", "unspec", "all")

    fun validInterfaceName(value: String): Boolean = interfacePattern.matches(value)

    fun validTableName(value: String): Boolean =
        tablePattern.matches(value) && value.lowercase() !in forbiddenTables

    fun discoverUniqueCellularTable(output: String, interfaceName: String): String? {
        if (!validInterfaceName(interfaceName)) return null
        val candidates = output.lineSequence().mapNotNull { line ->
            val tokens = tokens(line)
            if (tokens.firstOrNull() != "default") return@mapNotNull null
            val devIndex = tokens.indexOf("dev")
            val tableIndex = tokens.indexOf("table")
            if (devIndex < 0 || tableIndex < 0) return@mapNotNull null
            if (tokens.getOrNull(devIndex + 1) != interfaceName) return@mapNotNull null
            tokens.getOrNull(tableIndex + 1)?.takeIf(::validTableName)
        }.toSet()
        return candidates.singleOrNull()
    }

    fun hasDefaultRouteOnInterface(output: String, interfaceName: String): Boolean =
        output.lineSequence().any { line ->
            val tokens = tokens(line)
            val devIndex = tokens.indexOf("dev")
            tokens.firstOrNull() == "default" &&
                devIndex >= 0 &&
                tokens.getOrNull(devIndex + 1) == interfaceName
        }

    fun routeUsesInterface(output: String, interfaceName: String): Boolean =
        output.lineSequence().any { line ->
            val tokens = tokens(line)
            val devIndex = tokens.indexOf("dev")
            devIndex >= 0 && tokens.getOrNull(devIndex + 1) == interfaceName
        }

    fun hasGuard(output: String): Boolean = output.lineSequence().any { line ->
        val normalized = line.trim().lowercase()
        normalized.startsWith("$GUARD_PRIORITY:") &&
            normalized.contains("fwmark ${MARK.lowercase()}/${MASK.lowercase()}") &&
            normalized.contains("unreachable")
    }

    fun hasLookup(output: String, table: String): Boolean = output.lineSequence().any { line ->
        val normalized = line.trim().lowercase()
        normalized.startsWith("$LOOKUP_PRIORITY:") &&
            normalized.contains("fwmark ${MARK.lowercase()}/${MASK.lowercase()}") &&
            (normalized.contains("lookup ${table.lowercase()}") ||
                normalized.contains("table ${table.lowercase()}"))
    }

    fun hasAnyOwnedLookup(output: String): Boolean = output.lineSequence().any { line ->
        val normalized = line.trim().lowercase()
        normalized.startsWith("$LOOKUP_PRIORITY:") &&
            normalized.contains("fwmark ${MARK.lowercase()}/${MASK.lowercase()}")
    }

    private fun tokens(line: String): List<String> =
        line.trim().split(Regex("\\s+")).filter(String::isNotEmpty)
}

private const val MARK = "0x80000000"
private const val MASK = "0x80000000"
private const val LOOKUP_PRIORITY = 1000
private const val GUARD_PRIORITY = 1001
private const val IPV4_CHAIN = "MISH_CELLULAR_EGRESS"
private const val IPV6_CHAIN = "MISH_CELLULAR_V6"
