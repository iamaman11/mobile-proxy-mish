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
    data object Enforced : CellularRootPolicyResult

    data class FailClosed(
        val reason: CellularRootPolicyFailure? = null,
    ) : CellularRootPolicyResult

    data class AuthorityUnavailable(
        val status: RootAuthorityStatus,
    ) : CellularRootPolicyResult
}

/**
 * Narrow PRODUCT-owned root policy-routing adapter for Cellular Egress.
 *
 * The adapter owns no network admission state. One small deterministic candidate set is
 * audited against the live RPDB/mangle state and exactly one non-conflicting identity is
 * selected. Selection is runtime infrastructure state only; Cellular Egress remains the
 * sole semantic owner of admission and generation/currentness.
 *
 * PRODUCT UID -> MISH_EGRESS_V1
 *   -> loopback RETURN
 *   -> restore selected reserved bit from conntrack
 *   -> NEW flow: set selected packet bit and save it to conntrack
 * selected bit -> current direct-cellular IPv4 table
 * selected bit -> unreachable guard
 *
 * Saving/restoring the selected bit makes the routing decision flow-stable. Inbound Mesh
 * replies are ESTABLISHED and never acquire the PRODUCT NEW-flow mark. A referenced MISH
 * chain is immutable: detached state is fully populated and verified before one OUTPUT jump
 * is attached. Unsupported IPv6 receives only the selector plus unreachable guard.
 */
class CellularRootPolicy internal constructor(
    private val productUid: Int,
    private val authority: MagiskRootAuthority,
    private val process: RootProcess,
) : Closeable {
    constructor(productUid: Int) : this(productUid, MagiskRootAuthority(), SuProcess())

    private var activeIdentity: PolicyIdentity? = null

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

        when (resolvePolicyIdentity()) {
            PolicyIdentityResolution.Collision -> {
                val revoked = activeIdentity == null || removeOwnedIpv4Lookups()
                return CellularRootPolicyResult.FailClosed(
                    if (revoked) {
                        CellularRootPolicyFailure.ReservedPolicyCollision
                    } else {
                        CellularRootPolicyFailure.RuleMutationFailed
                    },
                )
            }

            PolicyIdentityResolution.Unavailable -> {
                val revoked = activeIdentity == null || removeOwnedIpv4Lookups()
                return CellularRootPolicyResult.FailClosed(
                    if (revoked) {
                        CellularRootPolicyFailure.VerificationFailed
                    } else {
                        CellularRootPolicyFailure.RuleMutationFailed
                    },
                )
            }

            PolicyIdentityResolution.Selected -> Unit
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

    /** Exact intentional teardown. Foreign overlapping state is never deleted or repurposed. */
    @Synchronized
    internal fun cleanupExactOwnedRules(): Boolean {
        if (authority.probe() != RootAuthorityStatus.Ready) return false

        if (activeIdentity == null) {
            when (resolvePolicyIdentity()) {
                PolicyIdentityResolution.Selected -> Unit
                PolicyIdentityResolution.Unavailable -> return false
                PolicyIdentityResolution.Collision -> {
                    // A collision before PRODUCT published anything needs no mutation.
                    return !hasAnyProductSignature()
                }
            }
        }

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
        if (mutatedCleanly && verifiedClean) activeIdentity = null
        return mutatedCleanly && verifiedClean
    }

    @Synchronized
    override fun close() {
        check(cleanupExactOwnedRules()) { "exact PRODUCT root-policy cleanup failed" }
    }

    private fun resolvePolicyIdentity(): PolicyIdentityResolution {
        val ipv4Rules = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return PolicyIdentityResolution.Unavailable
        val ipv6Rules = ruleOutputOrNull(IPV6_RULE_SHOW) ?: return PolicyIdentityResolution.Unavailable
        val ipv4Mangle = mangleOutputOrNull(IPTABLES) ?: return PolicyIdentityResolution.Unavailable
        val ipv6Mangle = mangleOutputOrNull(IP6TABLES) ?: return PolicyIdentityResolution.Unavailable

        val ipv4ChainExists = ipv4Mangle.any { it == "-N $MISH_CHAIN" }
        val ipv6ChainExists = ipv6Mangle.any { it == "-N $MISH_CHAIN" }
        val ipv4Chain = ipv4Mangle.filter { it.startsWith("-A $MISH_CHAIN ") }
        val ipv6Chain = ipv6Mangle.filter { it.startsWith("-A $MISH_CHAIN ") }
        val ipv4JumpCount = ipv4Mangle.count { it == ipv4OutputJump() }
        val ipv6JumpCount = ipv6Mangle.count { it == ipv6OutputJump() }

        if ((!ipv4ChainExists && ipv4JumpCount != 0) || (!ipv6ChainExists && ipv6JumpCount != 0)) {
            return PolicyIdentityResolution.Collision
        }
        if ((ipv4JumpCount != 0 && ipv4Chain.isEmpty()) ||
            (ipv6JumpCount != 0 && ipv6Chain.isEmpty())
        ) {
            return PolicyIdentityResolution.Collision
        }

        // Detached partial state is a recoverable interrupted PRODUCT publication only when
        // every present line is an ordered prefix of a known contract. A referenced partial
        // chain may resolve its identity here, but ensureMangleFamily() will still refuse to
        // flush/rewrite it while the OUTPUT jump is live.
        val hasChainState = ipv4Chain.isNotEmpty() || ipv6Chain.isNotEmpty()
        val compatible = POLICY_CANDIDATES.filter { candidate ->
            val expectedIpv4 = ipv4OwnedChainLines(candidate)
            val expectedIpv6 = ipv6OwnedChainLines(candidate)
            val ipv4Matches = ipv4Chain.isEmpty() ||
                (ipv4Chain.size <= expectedIpv4.size && ipv4Chain == expectedIpv4.take(ipv4Chain.size))
            val ipv6Matches = ipv6Chain.isEmpty() ||
                (ipv6Chain.size <= expectedIpv6.size && ipv6Chain == expectedIpv6.take(ipv6Chain.size))
            ipv4Matches && ipv6Matches
        }
        if (hasChainState && compatible.isEmpty()) {
            return PolicyIdentityResolution.Collision
        }

        val candidates = if (hasChainState) compatible else POLICY_CANDIDATES
        val preferred = activeIdentity
        if (preferred != null) {
            if (preferred !in candidates) {
                return PolicyIdentityResolution.Collision
            }
            activeIdentity = preferred
            if (auditReservedPolicySpace(ipv4Rules, ipv6Rules, ipv4Mangle, ipv6Mangle) ==
                PolicySpaceAudit.Clean
            ) {
                return PolicyIdentityResolution.Selected
            }
            return PolicyIdentityResolution.Collision
        }

        for (candidate in candidates) {
            activeIdentity = candidate
            if (auditReservedPolicySpace(ipv4Rules, ipv6Rules, ipv4Mangle, ipv6Mangle) ==
                PolicySpaceAudit.Clean
            ) {
                return PolicyIdentityResolution.Selected
            }
        }

        activeIdentity = null
        return PolicyIdentityResolution.Collision
    }

    private fun auditReservedPolicySpace(): PolicySpaceAudit {
        val ipv4Rules = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return PolicySpaceAudit.Unavailable
        val ipv6Rules = ruleOutputOrNull(IPV6_RULE_SHOW) ?: return PolicySpaceAudit.Unavailable
        val ipv4Mangle = mangleOutputOrNull(IPTABLES) ?: return PolicySpaceAudit.Unavailable
        val ipv6Mangle = mangleOutputOrNull(IP6TABLES) ?: return PolicySpaceAudit.Unavailable
        return auditReservedPolicySpace(ipv4Rules, ipv6Rules, ipv4Mangle, ipv6Mangle)
    }

    private fun auditReservedPolicySpace(
        ipv4Rules: List<String>,
        ipv6Rules: List<String>,
        ipv4Mangle: List<String>,
        ipv6Mangle: List<String>,
    ): PolicySpaceAudit {
        if (ipv4Rules.any(::isForeignReservedIpv4RpdbLine)) return PolicySpaceAudit.Collision
        if (ipv6Rules.any(::isForeignReservedIpv6RpdbLine)) return PolicySpaceAudit.Collision
        if (
            MangleOutputCollisionAudit.audit(
                lines = ipv4Mangle,
                allowedProductLines = ipv4AllowedMangleLines(),
                mishChain = MISH_CHAIN,
                candidateMark = MARK_VALUE,
            ) != MangleOutputCollisionAudit.Result.Clean
        ) {
            return PolicySpaceAudit.Collision
        }
        if (
            MangleOutputCollisionAudit.audit(
                lines = ipv6Mangle,
                allowedProductLines = ipv6AllowedMangleLines(),
                mishChain = MISH_CHAIN,
                candidateMark = MARK_VALUE,
            ) != MangleOutputCollisionAudit.Result.Clean
        ) {
            return PolicySpaceAudit.Collision
        }
        return PolicySpaceAudit.Clean
    }

    private fun isForeignReservedIpv4RpdbLine(line: String): Boolean {
        val trimmed = line.trim()
        if (OWNED_IPV4_LOOKUP_REGEX.matches(trimmed) || OWNED_IPV4_GUARD_REGEX.matches(trimmed)) {
            return false
        }
        val priority = trimmed.substringBefore(':').toIntOrNull()
        return priority == LOOKUP_PRIORITY || priority == GUARD_PRIORITY ||
            rpdbLineTouchesReservedMark(trimmed)
    }

    private fun isForeignReservedIpv6RpdbLine(line: String): Boolean {
        val trimmed = line.trim()
        if (OWNED_IPV6_GUARD_REGEX.matches(trimmed)) return false
        val priority = trimmed.substringBefore(':').toIntOrNull()
        return priority == LOOKUP_PRIORITY || priority == GUARD_PRIORITY ||
            rpdbLineTouchesReservedMark(trimmed)
    }

    private fun rpdbLineTouchesReservedMark(line: String): Boolean {
        val tokens = line.split(WHITESPACE_REGEX)
        val index = tokens.indexOf("fwmark")
        if (index < 0) return false
        val spec = tokens.getOrNull(index + 1) ?: return true
        return markSpecTouchesReservedBit(spec)
    }

    private fun markSpecTouchesReservedBit(spec: String): Boolean {
        val parts = spec.split('/', limit = 2)
        val value = parseUnsigned(parts[0]) ?: return true
        val mask = if (parts.size == 2) parseUnsigned(parts[1]) ?: return true else IPV4_FULL_MASK
        if (value > IPV4_FULL_MASK || mask > IPV4_FULL_MASK) return true
        return (mask and MARK_VALUE) != 0UL
    }

    private fun parseUnsigned(raw: String?): ULong? {
        if (raw == null) return null
        return if (raw.startsWith("0x", ignoreCase = true)) {
            raw.substring(2).toULongOrNull(16)
        } else {
            raw.toULongOrNull()
        }
    }

    private fun ensureFailClosedGuards(): Boolean =
        ensureRpdbGuard(IPV4_RULE_SHOW, ::isOwnedIpv4Guard, IPV4_GUARD_ADD) &&
            ensureRpdbGuard(IPV6_RULE_SHOW, ::isOwnedIpv6Guard, IPV6_GUARD_ADD)

    private fun ensureManglePolicy(): Boolean =
        ensureMangleFamily(IPTABLES, ipv4OwnedChainLines(), ipv4OutputJump()) &&
            ensureMangleFamily(IP6TABLES, ipv6OwnedChainLines(), ipv6OutputJump()) &&
            removeLegacySelectors()

    /** A referenced versioned chain is immutable; only detached state may be rebuilt. */
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
            if (jumpCount != 0) return false
            if (!commandSucceeded("$binary -t mangle -N $MISH_CHAIN")) return false
            chainExists = true
            actualChainLines = emptyList()
        }

        if (actualChainLines != expectedChainLines) {
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

    private fun hasAnyProductSignature(): Boolean {
        val ipv4Rules = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return true
        val ipv6Rules = ruleOutputOrNull(IPV6_RULE_SHOW) ?: return true
        val ipv4Mangle = mangleOutputOrNull(IPTABLES) ?: return true
        val ipv6Mangle = mangleOutputOrNull(IP6TABLES) ?: return true
        if (ipv4Mangle.any { it.contains(MISH_CHAIN) || it == legacyIpv4SelectorLine() }) return true
        if (ipv6Mangle.any { it.contains(MISH_CHAIN) || it == legacyIpv6SelectorLine() }) return true
        return POLICY_CANDIDATES.any { candidate ->
            val previous = activeIdentity
            activeIdentity = candidate
            val found = ipv4Rules.any { OWNED_IPV4_LOOKUP_REGEX.matches(it) || OWNED_IPV4_GUARD_REGEX.matches(it) } ||
                ipv6Rules.any { OWNED_IPV6_GUARD_REGEX.matches(it) }
            activeIdentity = previous
            found
        }
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

    private fun isOwnedIpv4Guard(line: String): Boolean = OWNED_IPV4_GUARD_REGEX.matches(line.trim())
    private fun isOwnedIpv6Guard(line: String): Boolean = OWNED_IPV6_GUARD_REGEX.matches(line.trim())

    private fun ruleOutputOrNull(command: String): List<String>? {
        val result = runRoot(command)
        if (result.timedOut || !result.outputComplete || result.exitCode != 0) return null
        return result.stdout.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
    }

    private fun mangleOutputOrNull(binary: String): List<String>? = ruleOutputOrNull("$binary -t mangle -S")

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

    private fun runRoot(command: String): RootProcessResult = process.run(listOf("su", "-c", command))

    private fun ipv4OutputJump(): String = "-A OUTPUT -m owner --uid-owner $productUid -j $MISH_CHAIN"
    private fun ipv6OutputJump(): String = "-A OUTPUT -m owner --uid-owner $productUid -j $MISH_CHAIN"

    private fun ipv4OwnedChainLines(): List<String> = ipv4OwnedChainLines(requireIdentity())
    private fun ipv6OwnedChainLines(): List<String> = ipv6OwnedChainLines(requireIdentity())

    private fun ipv4OwnedChainLines(identity: PolicyIdentity): List<String> = listOf(
        "-A $MISH_CHAIN -d 127.0.0.0/8 -j RETURN",
        "-A $MISH_CHAIN -j CONNMARK --restore-mark --nfmask ${identity.markHex} --ctmask ${identity.markHex}",
        "-A $MISH_CHAIN -m conntrack --ctstate NEW -j MARK --set-xmark ${identity.markHex}/${identity.markHex}",
        "-A $MISH_CHAIN -m conntrack --ctstate NEW -m mark --mark ${identity.markHex}/${identity.markHex} " +
            "-j CONNMARK --save-mark --nfmask ${identity.markHex} --ctmask ${identity.markHex}",
    )

    private fun ipv6OwnedChainLines(identity: PolicyIdentity): List<String> = listOf(
        "-A $MISH_CHAIN -d ::1/128 -j RETURN",
        "-A $MISH_CHAIN -j CONNMARK --restore-mark --nfmask ${identity.markHex} --ctmask ${identity.markHex}",
        "-A $MISH_CHAIN -m conntrack --ctstate NEW -j MARK --set-xmark ${identity.markHex}/${identity.markHex}",
        "-A $MISH_CHAIN -m conntrack --ctstate NEW -m mark --mark ${identity.markHex}/${identity.markHex} " +
            "-j CONNMARK --save-mark --nfmask ${identity.markHex} --ctmask ${identity.markHex}",
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
            "-j MARK --set-xmark $LEGACY_MARK_HEX/$LEGACY_MARK_HEX"

    private fun legacyIpv6SelectorLine(): String = legacyIpv4SelectorLine()

    private fun legacyIpv4SelectorCheck(): String =
        "iptables -t mangle -C OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $LEGACY_MARK_HEX/$LEGACY_MARK_HEX"

    private fun legacyIpv4SelectorDelete(): String =
        "iptables -t mangle -D OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $LEGACY_MARK_HEX/$LEGACY_MARK_HEX"

    private fun legacyIpv6SelectorCheck(): String =
        "ip6tables -t mangle -C OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $LEGACY_MARK_HEX/$LEGACY_MARK_HEX"

    private fun legacyIpv6SelectorDelete(): String =
        "ip6tables -t mangle -D OUTPUT -m owner --uid-owner $productUid " +
            "-m conntrack --ctstate NEW -j MARK --set-xmark $LEGACY_MARK_HEX/$LEGACY_MARK_HEX"

    private fun ipv4LookupAdd(table: String): String =
        "ip -4 rule add pref $LOOKUP_PRIORITY fwmark $MARK_HEX/$MASK_HEX lookup $table"

    private fun ipv4LookupDelete(table: String): String =
        "ip -4 rule del pref $LOOKUP_PRIORITY fwmark $MARK_HEX/$MASK_HEX lookup $table"

    private fun requireIdentity(): PolicyIdentity = checkNotNull(activeIdentity) {
        "root-policy identity must be resolved before mutation"
    }

    private val MARK_HEX: String get() = requireIdentity().markHex
    private val MASK_HEX: String get() = requireIdentity().markHex
    private val MARK_VALUE: ULong get() = requireIdentity().markValue
    private val LOOKUP_PRIORITY: Int get() = requireIdentity().lookupPriority
    private val GUARD_PRIORITY: Int get() = requireIdentity().guardPriority

    private val IPV4_GUARD_ADD: String
        get() = "ip -4 rule add pref $GUARD_PRIORITY fwmark $MARK_HEX/$MASK_HEX unreachable"
    private val IPV4_GUARD_DELETE: String
        get() = "ip -4 rule del pref $GUARD_PRIORITY fwmark $MARK_HEX/$MASK_HEX unreachable"
    private val IPV6_GUARD_ADD: String
        get() = "ip -6 rule add pref $GUARD_PRIORITY fwmark $MARK_HEX/$MASK_HEX unreachable"
    private val IPV6_GUARD_DELETE: String
        get() = "ip -6 rule del pref $GUARD_PRIORITY fwmark $MARK_HEX/$MASK_HEX unreachable"

    private val OWNED_IPV4_LOOKUP_REGEX: Regex
        get() = Regex(
            """${LOOKUP_PRIORITY}:\s+from\s+all\s+fwmark\s+${Regex.escape(MARK_HEX)}/${Regex.escape(MASK_HEX)}\s+lookup\s+([^\s]+).*""",
        )
    private val OWNED_IPV4_GUARD_REGEX: Regex
        get() = Regex(
            """${GUARD_PRIORITY}:\s+from\s+all\s+fwmark\s+${Regex.escape(MARK_HEX)}/${Regex.escape(MASK_HEX)}\s+unreachable.*""",
        )
    private val OWNED_IPV6_GUARD_REGEX: Regex
        get() = OWNED_IPV4_GUARD_REGEX

    private enum class PolicySpaceAudit { Clean, Collision, Unavailable }
    private enum class PolicyIdentityResolution { Selected, Collision, Unavailable }

    private data class PolicyIdentity(
        val markHex: String,
        val markValue: ULong,
        val lookupPriority: Int,
        val guardPriority: Int,
    )

    private companion object {
        // Use one small deterministic candidate set; every mark/mask/priority tuple is
        // accepted only after live RPDB/mangle collision audit on the target.
        val POLICY_CANDIDATES = listOf(
            PolicyIdentity("0x200000", 0x200000UL, 9500, 9501),
            PolicyIdentity("0x400000", 0x400000UL, 9520, 9521),
            PolicyIdentity("0x800000", 0x800000UL, 9540, 9541),
            PolicyIdentity("0x1000000", 0x1000000UL, 9560, 9561),
        )
        const val LEGACY_MARK_HEX = "0x200000"
        const val MAX_RECONCILE_PASSES = 8
        const val MISH_CHAIN = "MISH_EGRESS_V1"
        const val IPTABLES = "iptables"
        const val IP6TABLES = "ip6tables"
        const val IPV4_RULE_SHOW = "ip -4 rule show"
        const val IPV6_RULE_SHOW = "ip -6 rule show"
        const val IPV4_FULL_MASK = 0xffffffffUL
        val WHITESPACE_REGEX = Regex("""\s+""")

        fun isSafeInterfaceName(value: String): Boolean =
            value.length in 1..15 && Regex("""[A-Za-z0-9_.-]+""").matches(value)

        fun isSafeTableToken(value: String): Boolean =
            value.length in 1..32 && Regex("""[A-Za-z0-9_.-]+""").matches(value)
    }
}
