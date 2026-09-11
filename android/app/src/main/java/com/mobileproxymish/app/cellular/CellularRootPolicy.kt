package com.mobileproxymish.app.cellular

import java.io.Closeable

/** Why the root-policy adapter is currently fail-closed rather than enforcing cellular. */
enum class CellularRootPolicyFailure {
    InvalidProductUid,
    InvalidInterface,
    ReservedPolicyCollision,
    RouteTableDiscoveryFailed,
    RuleMutationFailed,
    VerificationFailed,
}

/**
 * Runtime result of the infrastructure adapter. This is not a second Cellular Egress
 * admission/readiness state; admission and generation remain owned by the Rust owner.
 */
sealed interface CellularRootPolicyResult {
    /** Owner is admitted and PRODUCT proxy flows are routed through the live cellular table. */
    data object Enforced : CellularRootPolicyResult

    /** PRODUCT proxy flows are protected by the same-mark unreachable guard. */
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
 * The adapter owns no network admission state. The caller supplies the Rust owner's exact
 * current decision plus a transient Android interface hint. Infrastructure is identified by
 * one dedicated MISH chain per address family and one reserved mark bit:
 *
 * PRODUCT UID -> MISH_EGRESS_V1
 *   -> loopback RETURN
 *   -> restore reserved bit from conntrack
 *   -> NEW flow: set reserved packet bit and save it to conntrack
 * reserved bit -> current direct-cellular IPv4 table
 * reserved bit -> unreachable guard
 *
 * Saving/restoring the bit makes the routing decision flow-stable: packets belonging to an
 * already selected proxy connection cannot silently lose the mark and fall through to the
 * Android default route. Inbound Mesh connections never acquire the MISH connmark because
 * their PRODUCT-side reply is ESTABLISHED rather than NEW. Loopback is returned explicitly
 * before any restore/mark operation.
 *
 * Reconciliation establishes fail-closed guards first, revokes any stale IPv4 lookup, then
 * verifies the exact MISH chain before an ADMITTED owner generation may install a fresh
 * cellular lookup. A referenced versioned MISH chain is immutable: it is never flushed or
 * rebuilt while OUTPUT can jump into it. Detached partial state may be rebuilt safely before
 * the jump is attached. IPv6 deliberately receives the same flow marking but only the
 * unreachable guard until a direct-cellular IPv6 path is separately accepted.
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

        when (auditReservedPolicySpace()) {
            PolicySpaceAudit.Collision ->
                return CellularRootPolicyResult.FailClosed(
                    CellularRootPolicyFailure.ReservedPolicyCollision,
                )

            PolicySpaceAudit.Unavailable ->
                return CellularRootPolicyResult.FailClosed(
                    CellularRootPolicyFailure.VerificationFailed,
                )

            PolicySpaceAudit.Clean -> Unit
        }

        // Generation transaction boundary:
        // 1) guards exist; 2) stale lookup is revoked; 3) exact MISH flow policy exists.
        // Only then may an admitted generation discover/install one fresh cellular lookup.
        if (!ensureFailClosedGuards()) {
            return CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.RuleMutationFailed)
        }
        if (!removeOwnedIpv4Lookups()) {
            return CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.RuleMutationFailed)
        }
        if (!ensureManglePolicy() || !verifyFailClosedBase()) {
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
     * Exact intentional teardown. Cleanup never deletes an unknown/foreign rule merely
     * because it overlaps the reserved space. It removes only exact PRODUCT signatures,
     * refuses to flush a MISH chain containing foreign content, and always post-verifies.
     */
    @Synchronized
    internal fun cleanupExactOwnedRules(): Boolean {
        var mutatedCleanly = true

        if (!removeOwnedIpv4Lookups()) mutatedCleanly = false
        if (!removeExactOutputJumps(IPTABLES, ipv4OutputJump())) mutatedCleanly = false
        if (!removeExactOutputJumps(IP6TABLES, ipv6OutputJump())) mutatedCleanly = false
        if (!removeLegacySelectors()) mutatedCleanly = false
        if (!removeOwnedChain(IPTABLES, ipv4OwnedChainLines())) mutatedCleanly = false
        if (!removeOwnedChain(IP6TABLES, ipv6OwnedChainLines())) mutatedCleanly = false
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

    private fun auditReservedPolicySpace(): PolicySpaceAudit {
        val ipv4Rules = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return PolicySpaceAudit.Unavailable
        val ipv6Rules = ruleOutputOrNull(IPV6_RULE_SHOW) ?: return PolicySpaceAudit.Unavailable
        val ipv4Mangle = mangleOutputOrNull(IPTABLES) ?: return PolicySpaceAudit.Unavailable
        val ipv6Mangle = mangleOutputOrNull(IP6TABLES) ?: return PolicySpaceAudit.Unavailable

        if (ipv4Rules.any(::isForeignReservedIpv4RpdbLine)) return PolicySpaceAudit.Collision
        if (ipv6Rules.any(::isForeignReservedIpv6RpdbLine)) return PolicySpaceAudit.Collision
        if (containsForeignReservedMangle(ipv4Mangle, ipv4AllowedMangleLines())) {
            return PolicySpaceAudit.Collision
        }
        if (containsForeignReservedMangle(ipv6Mangle, ipv6AllowedMangleLines())) {
            return PolicySpaceAudit.Collision
        }
        return PolicySpaceAudit.Clean
    }

    private fun isForeignReservedIpv4RpdbLine(line: String): Boolean {
        val trimmed = line.trim()
        return when {
            trimmed.startsWith("$LOOKUP_PRIORITY:") ->
                !OWNED_IPV4_LOOKUP_REGEX.matches(trimmed)
            trimmed.startsWith("$GUARD_PRIORITY:") ->
                !OWNED_IPV4_GUARD_REGEX.matches(trimmed)
            else -> false
        }
    }

    private fun isForeignReservedIpv6RpdbLine(line: String): Boolean {
        val trimmed = line.trim()
        return when {
            trimmed.startsWith("$LOOKUP_PRIORITY:") -> true
            trimmed.startsWith("$GUARD_PRIORITY:") ->
                !OWNED_IPV6_GUARD_REGEX.matches(trimmed)
            else -> false
        }
    }

    private fun containsForeignReservedMangle(
        lines: List<String>,
        allowed: Set<String>,
    ): Boolean = lines.any { line ->
        val trimmed = line.trim()
        val touchesIdentity = trimmed.contains(MISH_CHAIN)
        val touchesReservedMark = lineTouchesReservedMark(trimmed)
        (touchesIdentity || touchesReservedMark) && trimmed !in allowed
    }

    private fun lineTouchesReservedMark(line: String): Boolean {
        if (RESERVED_DECIMAL_REGEX.containsMatchIn(line)) return true
        return HEX_TOKEN_REGEX.findAll(line).any { match ->
            val value = match.value.removePrefix("0x").removePrefix("0X").toULongOrNull(16)
            value != null && (value and MARK_VALUE) != 0UL
        }
    }

    private fun ensureFailClosedGuards(): Boolean =
        ensureRpdbGuard(IPV4_RULE_SHOW, ::isOwnedIpv4Guard, IPV4_GUARD_ADD) &&
            ensureRpdbGuard(IPV6_RULE_SHOW, ::isOwnedIpv6Guard, IPV6_GUARD_ADD)

    private fun ensureManglePolicy(): Boolean =
        ensureMangleFamily(IPTABLES, ipv4OwnedChainLines(), ipv4OutputJump()) &&
            ensureMangleFamily(IP6TABLES, ipv6OwnedChainLines(), ipv6OutputJump()) &&
            removeLegacySelectors()

    /**
     * A referenced versioned chain is immutable. Reconciliation may only flush/rebuild a
     * detached chain. This guarantees that every OUTPUT jump is either absent or targets a
     * complete verified policy; there is never a live empty/partial chain between shell effects.
     */
    private fun ensureMangleFamily(
        binary: String,
        expectedChainLines: List<String>,
        outputJump: String,
    ): Boolean {
        var snapshot = mangleOutputOrNull(binary) ?: return false
        var chainExists = snapshot.any { it == "-N $MISH_CHAIN" }
        var actualChainLines = snapshot.filter { it.startsWith("-A $MISH_CHAIN ") }
        var jumpCount = snapshot.count { it == outputJump }

        if (!chainExists) {
            // A jump to a nonexistent user chain should be impossible in a valid ruleset.
            // Treat it as a malformed reserved state rather than attempting permissive repair.
            if (jumpCount != 0) return false
            if (!commandSucceeded("$binary -t mangle -N $MISH_CHAIN")) return false
            chainExists = true
            actualChainLines = emptyList()
        }

        if (actualChainLines != expectedChainLines) {
            // Rebuild is safe only while the chain is detached. Once referenced, V1 is
            // immutable; changing it requires a future versioned-chain migration.
            if (jumpCount != 0) return false
            if (!commandSucceeded("$binary -t mangle -F $MISH_CHAIN")) return false
            for (line in expectedChainLines) {
                if (!commandSucceeded("$binary -t mangle $line")) return false
            }
            snapshot = mangleOutputOrNull(binary) ?: return false
            chainExists = snapshot.any { it == "-N $MISH_CHAIN" }
            actualChainLines = snapshot.filter { it.startsWith("-A $MISH_CHAIN ") }
            jumpCount = snapshot.count { it == outputJump }
            if (!chainExists || actualChainLines != expectedChainLines || jumpCount != 0) {
                return false
            }
        }

        if (jumpCount == 0) {
            if (!commandSucceeded("$binary -t mangle $outputJump")) return false
            jumpCount = 1
        }
        while (jumpCount > 1) {
            if (!commandSucceeded("$binary -t mangle ${outputJump.replaceFirst("-A ", "-D ")}")) {
                return false
            }
            jumpCount -= 1
        }

        snapshot = mangleOutputOrNull(binary) ?: return false
        return snapshot.count { it == outputJump } == 1 &&
            snapshot.any { it == "-N $MISH_CHAIN" } &&
            snapshot.filter { it.startsWith("-A $MISH_CHAIN ") } == expectedChainLines
    }

    private fun removeLegacySelectors(): Boolean =
        removeExactRule(legacyIpv4SelectorCheck(), legacyIpv4SelectorDelete()) &&
            removeExactRule(legacyIpv6SelectorCheck(), legacyIpv6SelectorDelete())

    private fun verifyFailClosedBase(): Boolean {
        val ipv4Rules = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return false
        val ipv6Rules = ruleOutputOrNull(IPV6_RULE_SHOW) ?: return false
        return verifyMangleFamily(IPTABLES, ipv4OwnedChainLines(), ipv4OutputJump()) &&
            verifyMangleFamily(IP6TABLES, ipv6OwnedChainLines(), ipv6OutputJump()) &&
            ipv4Rules.any(::isOwnedIpv4Guard) &&
            ipv6Rules.any(::isOwnedIpv6Guard) &&
            ownedIpv4LookupTables(ipv4Rules).isEmpty() &&
            auditReservedPolicySpace() == PolicySpaceAudit.Clean
    }

    private fun verifyMangleFamily(
        binary: String,
        expectedChainLines: List<String>,
        outputJump: String,
    ): Boolean {
        val lines = mangleOutputOrNull(binary) ?: return false
        return lines.count { it == "-N $MISH_CHAIN" } == 1 &&
            lines.count { it == outputJump } == 1 &&
            lines.filter { it.startsWith("-A $MISH_CHAIN ") } == expectedChainLines
    }

    private fun verifyExactCleanup(): Boolean {
        if (authority.probe() != RootAuthorityStatus.Ready) return false
        val ipv4Rules = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return false
        val ipv6Rules = ruleOutputOrNull(IPV6_RULE_SHOW) ?: return false
        val ipv4Mangle = mangleOutputOrNull(IPTABLES) ?: return false
        val ipv6Mangle = mangleOutputOrNull(IP6TABLES) ?: return false
        return ownedIpv4LookupTables(ipv4Rules).isEmpty() &&
            ipv4Rules.none(::isOwnedIpv4Guard) &&
            ipv6Rules.none(::isOwnedIpv6Guard) &&
            ipv4Mangle.none { it.contains(MISH_CHAIN) || it == legacyIpv4SelectorLine() } &&
            ipv6Mangle.none { it.contains(MISH_CHAIN) || it == legacyIpv6SelectorLine() }
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

    private fun removeExactOutputJumps(binary: String, outputJump: String): Boolean {
        repeat(MAX_RECONCILE_PASSES) {
            val lines = mangleOutputOrNull(binary) ?: return false
            if (lines.none { it == outputJump }) return true
            if (!commandSucceeded("$binary -t mangle ${outputJump.replaceFirst("-A ", "-D ")}")) {
                return false
            }
        }
        return mangleOutputOrNull(binary)?.none { it == outputJump } == true
    }

    private fun removeOwnedChain(binary: String, allowedChainLines: List<String>): Boolean {
        val lines = mangleOutputOrNull(binary) ?: return false
        if (lines.none { it == "-N $MISH_CHAIN" }) return true
        val actual = lines.filter { it.startsWith("-A $MISH_CHAIN ") }
        if (actual.any { it !in allowedChainLines }) return false
        if (!commandSucceeded("$binary -t mangle -F $MISH_CHAIN")) return false
        if (!commandSucceeded("$binary -t mangle -X $MISH_CHAIN")) return false
        return mangleOutputOrNull(binary)?.none { it.contains(MISH_CHAIN) } == true
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

    private fun mangleOutputOrNull(binary: String): List<String>? =
        ruleOutputOrNull("$binary -t mangle -S")

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

    private fun ipv4OutputJump(): String =
        "-A OUTPUT -m owner --uid-owner $productUid -j $MISH_CHAIN"

    private fun ipv6OutputJump(): String =
        "-A OUTPUT -m owner --uid-owner $productUid -j $MISH_CHAIN"

    private fun ipv4OwnedChainLines(): List<String> = listOf(
        "-A $MISH_CHAIN -d 127.0.0.0/8 -j RETURN",
        "-A $MISH_CHAIN -j CONNMARK --restore-mark --nfmask $MASK_HEX --ctmask $MASK_HEX",
        "-A $MISH_CHAIN -m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX",
        "-A $MISH_CHAIN -m conntrack --ctstate NEW -m mark --mark $MARK_HEX/$MASK_HEX " +
            "-j CONNMARK --save-mark --nfmask $MASK_HEX --ctmask $MASK_HEX",
    )

    private fun ipv6OwnedChainLines(): List<String> = listOf(
        "-A $MISH_CHAIN -d ::1/128 -j RETURN",
        "-A $MISH_CHAIN -j CONNMARK --restore-mark --nfmask $MASK_HEX --ctmask $MASK_HEX",
        "-A $MISH_CHAIN -m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX",
        "-A $MISH_CHAIN -m conntrack --ctstate NEW -m mark --mark $MARK_HEX/$MASK_HEX " +
            "-j CONNMARK --save-mark --nfmask $MASK_HEX --ctmask $MASK_HEX",
    )

    private fun ipv4AllowedMangleLines(): Set<String> = buildSet {
        add("-N $MISH_CHAIN")
        add(ipv4OutputJump())
        addAll(ipv4OwnedChainLines())
        add(legacyIpv4SelectorLine())
    }

    private fun ipv6AllowedMangleLines(): Set<String> = buildSet {
        add("-N $MISH_CHAIN")
        add(ipv6OutputJump())
        addAll(ipv6OwnedChainLines())
        add(legacyIpv6SelectorLine())
    }

    private fun legacyIpv4SelectorLine(): String =
        "-A OUTPUT -m owner --uid-owner $productUid -m conntrack --ctstate NEW " +
            "-j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun legacyIpv6SelectorLine(): String =
        "-A OUTPUT -m owner --uid-owner $productUid -m conntrack --ctstate NEW " +
            "-j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun legacyIpv4SelectorCheck(): String =
        "iptables -t mangle -C OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun legacyIpv4SelectorDelete(): String =
        "iptables -t mangle -D OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun legacyIpv6SelectorCheck(): String =
        "ip6tables -t mangle -C OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun legacyIpv6SelectorDelete(): String =
        "ip6tables -t mangle -D OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $MARK_HEX/$MASK_HEX"

    private fun ipv4LookupAdd(table: String): String =
        "ip -4 rule add pref $LOOKUP_PRIORITY fwmark $MARK_HEX/$MASK_HEX lookup $table"

    private fun ipv4LookupDelete(table: String): String =
        "ip -4 rule del pref $LOOKUP_PRIORITY fwmark $MARK_HEX/$MASK_HEX lookup $table"

    private enum class PolicySpaceAudit {
        Clean,
        Collision,
        Unavailable,
    }

    private companion object {
        // Android 11 netd uses bits 0..20. Reserve bit 21 only and mask every MARK,
        // CONNMARK and RPDB operation so unrelated Android mark bits remain untouched.
        const val MARK_HEX = "0x200000"
        const val MASK_HEX = "0x200000"
        const val MARK_VALUE = 0x200000UL
        const val LOOKUP_PRIORITY = 9500
        const val GUARD_PRIORITY = 9501
        const val MAX_RECONCILE_PASSES = 8
        const val MISH_CHAIN = "MISH_EGRESS_V1"
        const val IPTABLES = "iptables"
        const val IP6TABLES = "ip6tables"

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
        val HEX_TOKEN_REGEX = Regex("""0[xX][0-9a-fA-F]+""")
        val RESERVED_DECIMAL_REGEX = Regex("""(?:^|\D)2097152(?:\D|$)""")

        fun isSafeInterfaceName(value: String): Boolean =
            value.length in 1..15 && Regex("""[A-Za-z0-9_.-]+""").matches(value)

        fun isSafeTableToken(value: String): Boolean =
            value.length in 1..32 && Regex("""[A-Za-z0-9_.-]+""").matches(value)
    }
}
