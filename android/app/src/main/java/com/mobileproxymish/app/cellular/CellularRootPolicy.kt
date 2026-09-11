package com.mobileproxymish.app.cellular

import java.io.Closeable

/** Why the root-policy adapter is currently fail-closed rather than enforcing cellular. */
enum class CellularRootPolicyFailure {
    InvalidProductUid,
    InvalidInterface,
    RouteTableDiscoveryFailed,
    RuleMutationFailed,
    VerificationFailed,
}

/**
 * Runtime result of the infrastructure adapter. This is not a second Cellular Egress
 * admission/readiness state; admission and generation remain owned by the Rust owner.
 */
sealed interface CellularRootPolicyResult {
    /** Owner is admitted and NEW PRODUCT flows are routed through the live cellular table. */
    data object Enforced : CellularRootPolicyResult

    /** PRODUCT-originated NEW public flows are protected by the same-mark unreachable guard. */
    data class FailClosed(
        val reason: CellularRootPolicyFailure? = null,
    ) : CellularRootPolicyResult

    /** Root authority itself is unavailable, so this adapter cannot claim enforcement. */
    data class AuthorityUnavailable(
        val status: RootAuthorityStatus,
    ) : CellularRootPolicyResult
}

/**
 * Narrow PRODUCT-owned root policy-routing adapter for Cellular Egress.
 *
 * The adapter deliberately owns no network admission state. The caller supplies the
 * owner's current decision plus a transient Android interface hint. The effective path
 * is ordered as:
 *
 * PRODUCT UID + conntrack NEW -> reserved masked mark
 * mark -> current direct-cellular IPv4 table
 * mark -> unreachable guard
 *
 * Every reconciliation first establishes the guards and revokes any previous cellular
 * lookup before a fresh owner generation can discover and install its table. A stale
 * generation therefore cannot remain usable while the new generation is being checked.
 * IPv6 gets the same NEW-flow mark plus only the unreachable guard until physical
 * direct-cellular IPv6 evidence exists. Established inbound Mesh replies are not NEW,
 * so they are not redirected by this selector.
 */
class CellularRootPolicy internal constructor(
    private val productUid: Int,
    private val authority: MagiskRootAuthority,
    private val process: RootProcess,
) : Closeable {
    constructor(productUid: Int) : this(productUid, MagiskRootAuthority(), SuProcess())

    @Synchronized
    fun failClosed(): CellularRootPolicyResult = reconcile(admitted = false, interfaceName = null)

    @Synchronized
    fun reconcile(
        admitted: Boolean,
        interfaceName: String?,
    ): CellularRootPolicyResult {
        val authorityStatus = authority.probe()
        if (authorityStatus != RootAuthorityStatus.Ready) {
            return CellularRootPolicyResult.AuthorityUnavailable(authorityStatus)
        }
        if (productUid <= 0) {
            return CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.InvalidProductUid)
        }

        // Transaction boundary for every owner generation:
        // 1) guards exist, 2) stale cellular lookup is revoked, 3) selectors/base are
        // verified. Only then may an admitted generation discover/install a fresh lookup.
        if (!ensureFailClosedGuards()) {
            return CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.RuleMutationFailed)
        }
        if (!removeOwnedIpv4Lookups()) {
            return CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.RuleMutationFailed)
        }
        if (!ensureSelectors() || !verifyFailClosedBase()) {
            return CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.RuleMutationFailed)
        }

        if (!admitted) {
            return CellularRootPolicyResult.FailClosed()
        }

        val iface = interfaceName?.takeIf { isSafeInterfaceName(it) }
            ?: return CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.InvalidInterface)

        val table = discoverValidatedIpv4Table(iface)
            ?: return CellularRootPolicyResult.FailClosed(
                CellularRootPolicyFailure.RouteTableDiscoveryFailed,
            )

        if (!replaceIpv4Lookup(table)) {
            removeOwnedIpv4Lookups()
            return CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.RuleMutationFailed)
        }

        if (!verifyIpv4Path(iface)) {
            removeOwnedIpv4Lookups()
            return CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.VerificationFailed)
        }

        return CellularRootPolicyResult.Enforced
    }

    /**
     * Exact intentional teardown. Unlike startup admission, cleanup must not skip its
     * delete attempts merely because a preliminary authority probe is transiently
     * incomplete. It attempts every exact PRODUCT-owned signature, then independently
     * verifies that root authority is usable and all signatures are absent.
     */
    @Synchronized
    internal fun cleanupExactOwnedRules(): Boolean {
        var mutatedCleanly = true

        if (!removeOwnedIpv4Lookups()) mutatedCleanly = false
        if (!removeExactRule(ipv4SelectorCheck(), ipv4SelectorDelete())) mutatedCleanly = false
        if (!removeExactRule(ipv6SelectorCheck(), ipv6SelectorDelete())) mutatedCleanly = false
        if (!removeRpdbGuard(IPV4_RULE_SHOW, ::isOwnedIpv4Guard, IPV4_GUARD_DELETE)) {
            mutatedCleanly = false
        }
        if (!removeRpdbGuard(IPV6_RULE_SHOW, ::isOwnedIpv6Guard, IPV6_GUARD_DELETE)) {
            mutatedCleanly = false
        }

        val verifiedClean = verifyExactCleanup()
        return mutatedCleanly && verifiedClean
    }

    @Synchronized
    override fun close() {
        check(cleanupExactOwnedRules()) { "exact PRODUCT root-policy cleanup failed" }
    }

    private fun ensureFailClosedGuards(): Boolean =
        ensureRpdbGuard(IPV4_RULE_SHOW, ::isOwnedIpv4Guard, IPV4_GUARD_ADD) &&
            ensureRpdbGuard(IPV6_RULE_SHOW, ::isOwnedIpv6Guard, IPV6_GUARD_ADD)

    private fun ensureSelectors(): Boolean =
        ensureExactRule(ipv4SelectorCheck(), ipv4SelectorAdd()) &&
            ensureExactRule(ipv6SelectorCheck(), ipv6SelectorAdd())

    private fun verifyFailClosedBase(): Boolean {
        val ipv4Rules = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return false
        val ipv6Rules = ruleOutputOrNull(IPV6_RULE_SHOW) ?: return false
        return commandSucceeded(ipv4SelectorCheck()) &&
            commandSucceeded(ipv6SelectorCheck()) &&
            ipv4Rules.any(::isOwnedIpv4Guard) &&
            ipv6Rules.any(::isOwnedIpv6Guard) &&
            ownedIpv4LookupTables(ipv4Rules).isEmpty()
    }

    private fun verifyExactCleanup(): Boolean {
        if (authority.probe() != RootAuthorityStatus.Ready) return false
        val ipv4Rules = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return false
        val ipv6Rules = ruleOutputOrNull(IPV6_RULE_SHOW) ?: return false
        return !commandSucceeded(ipv4SelectorCheck()) &&
            !commandSucceeded(ipv6SelectorCheck()) &&
            ownedIpv4LookupTables(ipv4Rules).isEmpty() &&
            ipv4Rules.none(::isOwnedIpv4Guard) &&
            ipv6Rules.none(::isOwnedIpv6Guard)
    }

    private fun ensureExactRule(check: String, add: String): Boolean {
        if (commandSucceeded(check)) return true
        if (!commandSucceeded(add)) return false
        return commandSucceeded(check)
    }

    private fun ensureRpdbGuard(
        showCommand: String,
        ownedLineMatcher: (String) -> Boolean,
        addCommand: String,
    ): Boolean {
        val lines = ruleOutputOrNull(showCommand) ?: return false
        if (lines.any(ownedLineMatcher)) return true
        if (!commandSucceeded(addCommand)) return false
        return ruleOutputOrNull(showCommand)?.any(ownedLineMatcher) == true
    }

    private fun removeRpdbGuard(
        showCommand: String,
        ownedLineMatcher: (String) -> Boolean,
        deleteCommand: String,
    ): Boolean {
        repeat(MAX_RECONCILE_PASSES) {
            val lines = ruleOutputOrNull(showCommand) ?: return false
            if (lines.none(ownedLineMatcher)) return true
            if (!commandSucceeded(deleteCommand)) return false
        }
        return ruleOutputOrNull(showCommand)?.none(ownedLineMatcher) == true
    }

    private fun discoverValidatedIpv4Table(iface: String): String? {
        val result = runRoot("ip -4 route show table all dev $iface")
        if (result.timedOut || !result.outputComplete || result.exitCode != 0) return null

        val tables = result.stdout.lineSequence()
            .map(String::trim)
            .filter { it.startsWith("default ") || it == "default" }
            .filter { Regex("""(?:^|\s)dev\s+${Regex.escape(iface)}(?:\s|$)""").containsMatchIn(it) }
            .mapNotNull { line ->
                Regex("""(?:^|\s)table\s+([^\s]+)(?:\s|$)""")
                    .find(line)
                    ?.groupValues
                    ?.get(1)
                    ?.takeIf { isSafeTableToken(it) }
            }
            .distinct()
            .toList()

        if (tables.size != 1) return null
        val table = tables.single()

        val verify = runRoot("ip -4 route show table $table default dev $iface")
        if (verify.timedOut || !verify.outputComplete || verify.exitCode != 0) return null
        val verified = verify.stdout.lineSequence().map(String::trim).any { line ->
            (line.startsWith("default ") || line == "default") &&
                Regex("""(?:^|\s)dev\s+${Regex.escape(iface)}(?:\s|$)""").containsMatchIn(line)
        }
        return table.takeIf { verified }
    }

    private fun replaceIpv4Lookup(table: String): Boolean {
        val initialRules = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return false
        val existing = ownedIpv4LookupTables(initialRules)

        for (stale in existing.filterNot { it == table }) {
            if (!commandSucceeded(ipv4LookupDelete(stale))) return false
        }

        val afterDelete = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return false
        if (ownedIpv4LookupTables(afterDelete).contains(table)) return true

        if (!commandSucceeded(ipv4LookupAdd(table))) return false
        return ruleOutputOrNull(IPV4_RULE_SHOW)
            ?.let(::ownedIpv4LookupTables)
            ?.contains(table) == true
    }

    private fun removeOwnedIpv4Lookups(): Boolean {
        repeat(MAX_RECONCILE_PASSES) {
            val lines = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return false
            val tables = ownedIpv4LookupTables(lines)
            if (tables.isEmpty()) return true
            for (table in tables) {
                if (!commandSucceeded(ipv4LookupDelete(table))) return false
            }
        }
        return ruleOutputOrNull(IPV4_RULE_SHOW)
            ?.let(::ownedIpv4LookupTables)
            ?.isEmpty() == true
    }

    private fun verifyIpv4Path(iface: String): Boolean {
        val lookup = runRoot("ip -4 route get 1.1.1.1 mark $MARK_HEX")
        if (lookup.timedOut || !lookup.outputComplete || lookup.exitCode != 0) return false
        return Regex("""(?:^|\s)dev\s+${Regex.escape(iface)}(?:\s|$)""")
            .containsMatchIn(lookup.stdout)
    }

    private fun ownedIpv4LookupTables(lines: List<String>): List<String> = lines.mapNotNull { line ->
        OWNED_IPV4_LOOKUP_REGEX.matchEntire(line.trim())?.groupValues?.get(1)
    }.filter { isSafeTableToken(it) }.distinct()

    private fun isOwnedIpv4Guard(line: String): Boolean =
        OWNED_IPV4_GUARD_REGEX.matches(line.trim())

    private fun isOwnedIpv6Guard(line: String): Boolean =
        OWNED_IPV6_GUARD_REGEX.matches(line.trim())

    private fun ruleOutputOrNull(command: String): List<String>? {
        val result = runRoot(command)
        if (result.timedOut || !result.outputComplete || result.exitCode != 0) return null
        return result.stdout.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
    }

    private fun commandSucceeded(command: String): Boolean {
        val result = runRoot(command)
        return !result.timedOut && result.outputComplete && result.exitCode == 0
    }

    private fun removeExactRule(checkCommand: String, deleteCommand: String): Boolean {
        repeat(MAX_RECONCILE_PASSES) {
            val check = runRoot(checkCommand)
            if (check.timedOut || !check.outputComplete) return false
            if (check.exitCode != 0) return true
            if (!commandSucceeded(deleteCommand)) return false
        }
        val finalCheck = runRoot(checkCommand)
        return !finalCheck.timedOut && finalCheck.outputComplete && finalCheck.exitCode != 0
    }

    private fun runRoot(command: String): RootProcessResult =
        process.run(listOf("su", "-c", command))

    private fun ipv4SelectorCheck(): String =
        "iptables -t mangle -C OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun ipv4SelectorAdd(): String =
        "iptables -t mangle -A OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun ipv4SelectorDelete(): String =
        "iptables -t mangle -D OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun ipv6SelectorCheck(): String =
        "ip6tables -t mangle -C OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun ipv6SelectorAdd(): String =
        "ip6tables -t mangle -A OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun ipv6SelectorDelete(): String =
        "ip6tables -t mangle -D OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun ipv4LookupAdd(table: String): String =
        "ip -4 rule add pref $LOOKUP_PRIORITY fwmark $MARK_HEX/$MASK_HEX lookup $table"

    private fun ipv4LookupDelete(table: String): String =
        "ip -4 rule del pref $LOOKUP_PRIORITY fwmark $MARK_HEX/$MASK_HEX lookup $table"

    private companion object {
        // Android 11 netd uses bits 0..20; this single reserved bit is deliberately
        // masked so PRODUCT policy does not overwrite Android's netId/permission bits.
        const val MARK_HEX = "0x200000"
        const val MASK_HEX = "0x200000"
        const val LOOKUP_PRIORITY = 9500
        const val MAX_RECONCILE_PASSES = 8

        const val IPV4_RULE_SHOW = "ip -4 rule show"
        const val IPV6_RULE_SHOW = "ip -6 rule show"

        const val IPV4_GUARD_ADD =
            "ip -4 rule add pref 9501 fwmark 0x200000/0x200000 unreachable"
        const val IPV4_GUARD_DELETE =
            "ip -4 rule del pref 9501 fwmark 0x200000/0x200000 unreachable"
        const val IPV6_GUARD_ADD =
            "ip -6 rule add pref 9501 fwmark 0x200000/0x200000 unreachable"
        const val IPV6_GUARD_DELETE =
            "ip -6 rule del pref 9501 fwmark 0x200000/0x200000 unreachable"

        val OWNED_IPV4_LOOKUP_REGEX = Regex(
            """9500:\s+from\s+all\s+fwmark\s+0x200000/0x200000\s+lookup\s+([^\s]+).*""",
        )
        val OWNED_IPV4_GUARD_REGEX = Regex(
            """9501:\s+from\s+all\s+fwmark\s+0x200000/0x200000\s+unreachable.*""",
        )
        val OWNED_IPV6_GUARD_REGEX = Regex(
            """9501:\s+from\s+all\s+fwmark\s+0x200000/0x200000\s+unreachable.*""",
        )

        fun isSafeInterfaceName(value: String): Boolean =
            value.length in 1..15 && Regex("""[A-Za-z0-9_.-]+""").matches(value)

        fun isSafeTableToken(value: String): Boolean =
            value.length in 1..32 && Regex("""[A-Za-z0-9_.-]+""").matches(value)
    }
}
