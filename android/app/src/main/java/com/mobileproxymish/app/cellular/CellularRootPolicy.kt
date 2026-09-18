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
    MangleChainCreationFailed,
    OwnerNewMarkRuleFailed,
    OutputJumpCreationFailed,
    MangleVerificationFailed,
    LookupRuleCreationFailed,
    RouteLookupVerificationFailed,
    ExactCleanupFailed,
}

/**
 * Runtime result of the infrastructure adapter. This is not a second Cellular Egress
 * admission/readiness state; admission and generation remain owned by the Rust owner.
 */
internal enum class CellularRootPolicyCleanupFailure {
    IDENTITY_UNAVAILABLE,
    IDENTITY_COLLISION,
    IPV4_LOOKUP_DELETE_FAILED,
    IPV4_OUTPUT_JUMP_DELETE_FAILED,
    IPV4_LEGACY_SELECTOR_DELETE_FAILED,
    IPV4_CHAIN_DELETE_FAILED,
    IPV4_GUARD_DELETE_FAILED,
    IPV6_OUTPUT_JUMP_DELETE_FAILED,
    IPV6_LEGACY_SELECTOR_DELETE_FAILED,
    IPV6_CHAIN_DELETE_FAILED,
    IPV6_GUARD_DELETE_FAILED,
    FINAL_VERIFICATION_FAILED,
}

internal data class CellularRootPolicyReconcileDiagnostic(
    val attempts: Long = 0,
    val totalExecutorCommands: Long = 0,
    val totalObservationCommands: Long = 0,
    val totalMutationCommands: Long = 0,
    val totalDuplicateObservations: Long = 0,
    val lastReconcileElapsedMs: Long = 0,
    val maxReconcileElapsedMs: Long = 0,
    val lastPolicyEffectElapsedMs: Long = 0,
    val maxPolicyEffectElapsedMs: Long = 0,
    val lastExecutorCommands: Int = 0,
    val lastObservationCommands: Int = 0,
    val lastMutationCommands: Int = 0,
    val lastDuplicateObservations: Int = 0,
    val lastIncompleteOrTimedOutCommands: Int = 0,
    val lastMutationFailures: Int = 0,
)

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
 * Narrow PRODUCT-owned root policy-routing transaction facade for Cellular Egress.
 *
 * RootPolicyExecutor owns bounded root effects, RootPolicySnapshot owns pure RPDB parsing, and
 * DirectCellularRouteInspector owns read-only route validation. This facade alone sequences the
 * fail-closed transaction and owns no network admission state. Cellular Egress remains the sole
 * semantic owner of admission and generation/currentness.
 *
 * PRODUCT UID -> MISH_EGRESS_V1
 *   -> loopback RETURN
 *   -> restore selected reserved bit from conntrack
 *   -> NEW flow: set selected packet bit and save it to conntrack
 * selected bit -> current direct-cellular IPv4 table
 * selected bit -> unreachable guard
 *
 * Saving/restoring the selected bit makes the routing decision flow-stable. Inbound Mesh replies
 * are ESTABLISHED and never acquire the PRODUCT NEW-flow mark. A referenced MISH chain is
 * immutable: detached state is fully populated and verified before one OUTPUT jump is attached.
 * Unsupported IPv6 receives only the selector plus unreachable guard.
 */
class CellularRootPolicy internal constructor(
    private val productUid: Int,
    private val authority: MagiskRootAuthority,
    private val process: RootProcess,
    // A local debug package has a distinct Android UID. It must never claim or clean the
    // release package's global root-policy objects during DEVICE-1 diagnostics.
    private val debugIsolation: Boolean = false,
) : Closeable {
    constructor(productUid: Int) : this(productUid, MagiskRootAuthority(), SuProcess())

    internal constructor(productUid: Int, debugIsolation: Boolean) :
        this(productUid, MagiskRootAuthority(), SuProcess(), debugIsolation)

    private val executor = RootPolicyExecutor(process)
    private val routeInspector = DirectCellularRouteInspector(executor)
    private var activeIdentity: PolicyIdentity? = null
    /** Sanitized teardown stage for lifecycle/E3 evidence; never contains commands or addresses. */
    private var lastCleanupFailure: CellularRootPolicyFailure? = null
    private var lastCleanupStage: CellularRootPolicyCleanupFailure? = null
    private var reconcileDiagnostic = CellularRootPolicyReconcileDiagnostic()

    @Synchronized
    fun failClosed(): CellularRootPolicyResult = reconcile(admitted = false, interfaceName = null)

    @Synchronized
    fun reconcile(
        admitted: Boolean,
        interfaceName: String?,
    ): CellularRootPolicyResult {
        val reconcileStartedNanos = System.nanoTime()
        var policyEffectStartedNanos: Long? = null
        executor.beginDiagnosticWindow()
        try {
            val authorityStatus = authority.probe()
            if (authorityStatus != RootAuthorityStatus.Ready) {
                return CellularRootPolicyResult.AuthorityUnavailable(authorityStatus)
            }
            // The executor window deliberately excludes Magisk authority/bootstrap commands.
            // Keep a separate policy-effect elapsed value so command counts and timing are not
            // accidentally interpreted as measuring different boundaries.
            policyEffectStartedNanos = System.nanoTime()
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
            when (val mangle = ensureManglePolicy()) {
                ManglePolicyResult.Enforced -> Unit
                is ManglePolicyResult.Failed ->
                    return CellularRootPolicyResult.FailClosed(mangle.failure)
            }
            if (!verifyFailClosedBase()) {
                return CellularRootPolicyResult.FailClosed(
                    CellularRootPolicyFailure.MangleVerificationFailed,
                )
            }

            if (!admitted) {
                return CellularRootPolicyResult.FailClosed()
            }

            val iface = interfaceName?.takeIf(RootPolicySnapshot::isSafeInterfaceName)
                ?: return CellularRootPolicyResult.FailClosed(
                    CellularRootPolicyFailure.InvalidInterface,
                )

            val table = routeInspector.discoverValidatedIpv4Table(iface, IPV4_RULE_SHOW)
                ?: return CellularRootPolicyResult.FailClosed(
                    CellularRootPolicyFailure.RouteTableDiscoveryFailed,
                )

            if (!replaceIpv4Lookup(table)) {
                removeOwnedIpv4Lookups()
                return CellularRootPolicyResult.FailClosed(
                    CellularRootPolicyFailure.LookupRuleCreationFailed,
                )
            }

            if (!routeInspector.verifyIpv4Path(iface, MARK_HEX)) {
                removeOwnedIpv4Lookups()
                return CellularRootPolicyResult.FailClosed(
                    CellularRootPolicyFailure.RouteLookupVerificationFailed,
                )
            }

            return CellularRootPolicyResult.Enforced
        } finally {
            val finishedNanos = System.nanoTime()
            val reconcileElapsedMs =
                ((finishedNanos - reconcileStartedNanos) / 1_000_000L).coerceAtLeast(0L)
            val policyEffectElapsedMs = policyEffectStartedNanos?.let { started ->
                ((finishedNanos - started) / 1_000_000L).coerceAtLeast(0L)
            } ?: 0L
            val window = executor.finishDiagnosticWindow()
            val previous = reconcileDiagnostic
            reconcileDiagnostic = previous.copy(
                attempts = previous.attempts + 1,
                totalExecutorCommands = previous.totalExecutorCommands + window.commands,
                totalObservationCommands =
                    previous.totalObservationCommands + window.observationCommands,
                totalMutationCommands = previous.totalMutationCommands + window.mutationCommands,
                totalDuplicateObservations =
                    previous.totalDuplicateObservations + window.duplicateObservations,
                lastReconcileElapsedMs = reconcileElapsedMs,
                maxReconcileElapsedMs =
                    maxOf(previous.maxReconcileElapsedMs, reconcileElapsedMs),
                lastPolicyEffectElapsedMs = policyEffectElapsedMs,
                maxPolicyEffectElapsedMs =
                    maxOf(previous.maxPolicyEffectElapsedMs, policyEffectElapsedMs),
                lastExecutorCommands = window.commands,
                lastObservationCommands = window.observationCommands,
                lastMutationCommands = window.mutationCommands,
                lastDuplicateObservations = window.duplicateObservations,
                lastIncompleteOrTimedOutCommands = window.incompleteOrTimedOutCommands,
                lastMutationFailures = window.mutationFailures,
            )
        }
    }

    @Synchronized
    internal fun reconcileDiagnosticObservation(): CellularRootPolicyReconcileDiagnostic =
        reconcileDiagnostic

    /**
     * Exact intentional teardown. Cleanup attempts every exact PRODUCT-owned delete before
     * authoritative post-verification. A transient preliminary authority probe must not skip
     * teardown and leave stale routing state behind.
     */
    @Synchronized
    internal fun cleanupExactOwnedRules(): Boolean {
        lastCleanupFailure = null
        lastCleanupStage = null

        if (activeIdentity == null) {
            when (resolvePolicyIdentity()) {
                PolicyIdentityResolution.Selected -> Unit
                PolicyIdentityResolution.Unavailable ->
                    return cleanupFailed(CellularRootPolicyCleanupFailure.IDENTITY_UNAVAILABLE)
                PolicyIdentityResolution.Collision -> {
                    // A collision before PRODUCT published anything needs no mutation.
                    if (hasAnyProductSignature()) {
                        return cleanupFailed(CellularRootPolicyCleanupFailure.IDENTITY_COLLISION)
                    }
                    return true
                }
            }
        }

        var mutatedCleanly = true
        if (!removeOwnedIpv4Lookups()) {
            recordCleanupFailure(CellularRootPolicyCleanupFailure.IPV4_LOOKUP_DELETE_FAILED)
            mutatedCleanly = false
        }

        // Cleanup is dependency-aware per address family. The fail-closed guard must remain
        // installed until every PRODUCT mark producer is detached and the referenced chain is
        // gone. Otherwise a failed OUTPUT-jump delete followed by a chain flush can publish the
        // forbidden live-jump -> empty-chain state observed on DEVICE-1 after U2 run #214.
        val ipv4JumpDetached = removeExactOutputJumps(IPTABLES, ipv4OutputJump())
        val ipv4LegacyDetached =
            removeExactRule(legacyIpv4SelectorCheck(), legacyIpv4SelectorDelete())
        if (!ipv4JumpDetached) {
            recordCleanupFailure(CellularRootPolicyCleanupFailure.IPV4_OUTPUT_JUMP_DELETE_FAILED)
            mutatedCleanly = false
        }
        if (!ipv4LegacyDetached) {
            recordCleanupFailure(CellularRootPolicyCleanupFailure.IPV4_LEGACY_SELECTOR_DELETE_FAILED)
            mutatedCleanly = false
        }
        if (ipv4JumpDetached && ipv4LegacyDetached) {
            val ipv4ChainRemoved = removeOwnedChain(IPTABLES, ipv4OwnedChainLines())
            if (!ipv4ChainRemoved) {
                recordCleanupFailure(CellularRootPolicyCleanupFailure.IPV4_CHAIN_DELETE_FAILED)
                mutatedCleanly = false
            } else if (!removeRpdbGuard(IPV4_RULE_SHOW, ::isOwnedIpv4Guard, IPV4_GUARD_DELETE)) {
                recordCleanupFailure(CellularRootPolicyCleanupFailure.IPV4_GUARD_DELETE_FAILED)
                mutatedCleanly = false
            }
        }

        val ipv6JumpDetached = removeExactOutputJumps(IP6TABLES, ipv6OutputJump())
        val ipv6LegacyDetached =
            removeExactRule(legacyIpv6SelectorCheck(), legacyIpv6SelectorDelete())
        if (!ipv6JumpDetached) {
            recordCleanupFailure(CellularRootPolicyCleanupFailure.IPV6_OUTPUT_JUMP_DELETE_FAILED)
            mutatedCleanly = false
        }
        if (!ipv6LegacyDetached) {
            recordCleanupFailure(CellularRootPolicyCleanupFailure.IPV6_LEGACY_SELECTOR_DELETE_FAILED)
            mutatedCleanly = false
        }
        if (ipv6JumpDetached && ipv6LegacyDetached) {
            val ipv6ChainRemoved = removeOwnedChain(IP6TABLES, ipv6OwnedChainLines())
            if (!ipv6ChainRemoved) {
                recordCleanupFailure(CellularRootPolicyCleanupFailure.IPV6_CHAIN_DELETE_FAILED)
                mutatedCleanly = false
            } else if (!removeRpdbGuard(IPV6_RULE_SHOW, ::isOwnedIpv6Guard, IPV6_GUARD_DELETE)) {
                recordCleanupFailure(CellularRootPolicyCleanupFailure.IPV6_GUARD_DELETE_FAILED)
                mutatedCleanly = false
            }
        }

        val verifiedClean = verifyExactCleanup()
        if (!verifiedClean) {
            recordCleanupFailure(CellularRootPolicyCleanupFailure.FINAL_VERIFICATION_FAILED)
        }
        if (!mutatedCleanly || !verifiedClean) lastCleanupFailure = CellularRootPolicyFailure.ExactCleanupFailed
        if (mutatedCleanly && verifiedClean) activeIdentity = null
        return mutatedCleanly && verifiedClean
    }

    private fun recordCleanupFailure(stage: CellularRootPolicyCleanupFailure) {
        if (lastCleanupStage == null) lastCleanupStage = stage
        lastCleanupFailure = CellularRootPolicyFailure.ExactCleanupFailed
    }

    private fun cleanupFailed(stage: CellularRootPolicyCleanupFailure): Boolean {
        recordCleanupFailure(stage)
        return false
    }

    @Synchronized
    internal fun cleanupFailureStage(): CellularRootPolicyCleanupFailure? = lastCleanupStage

    @Synchronized
    override fun close() {
        check(cleanupExactOwnedRules()) {
            "exact PRODUCT root-policy cleanup failed: " +
                "${cleanupFailureStage()?.name ?: lastCleanupFailure?.name ?: "UNKNOWN"}"
        }
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
            RootPolicySnapshot.rpdbLineTouchesReservedMark(trimmed, MARK_VALUE)
    }

    private fun isForeignReservedIpv6RpdbLine(line: String): Boolean {
        val trimmed = line.trim()
        if (OWNED_IPV6_GUARD_REGEX.matches(trimmed)) return false
        val priority = trimmed.substringBefore(':').toIntOrNull()
        return priority == LOOKUP_PRIORITY || priority == GUARD_PRIORITY ||
            RootPolicySnapshot.rpdbLineTouchesReservedMark(trimmed, MARK_VALUE)
    }

    private fun ensureFailClosedGuards(): Boolean =
        ensureRpdbGuard(IPV4_RULE_SHOW, ::isOwnedIpv4Guard, IPV4_GUARD_ADD) &&
            ensureRpdbGuard(IPV6_RULE_SHOW, ::isOwnedIpv6Guard, IPV6_GUARD_ADD)

    private fun ensureManglePolicy(): ManglePolicyResult {
        val ipv4 = ensureMangleFamily(IPTABLES, ipv4OwnedChainLines(), ipv4OutputJump())
        if (ipv4 != null) return ManglePolicyResult.Failed(ipv4)
        val ipv6 = ensureMangleFamily(IP6TABLES, ipv6OwnedChainLines(), ipv6OutputJump())
        if (ipv6 != null) return ManglePolicyResult.Failed(ipv6)
        return if (removeLegacySelectors()) {
            ManglePolicyResult.Enforced
        } else {
            ManglePolicyResult.Failed(CellularRootPolicyFailure.OwnerNewMarkRuleFailed)
        }
    }

    /** A referenced versioned chain is immutable; only detached state may be rebuilt. */
    private fun ensureMangleFamily(
        binary: String,
        expectedChainLines: List<String>,
        outputJump: String,
    ): CellularRootPolicyFailure? {
        var snapshot = mangleOutputOrNull(binary) ?: return CellularRootPolicyFailure.MangleVerificationFailed
        var chainExists = snapshot.any { it == "-N $MISH_CHAIN" }
        var actualChainLines = snapshot.filter { it.startsWith("-A $MISH_CHAIN ") }
        var jumpCount = snapshot.count { it == outputJump }

        if (!chainExists) {
            if (jumpCount != 0) return CellularRootPolicyFailure.MangleVerificationFailed
            if (!commandSucceeded("$binary -t mangle -N $MISH_CHAIN")) {
                return CellularRootPolicyFailure.MangleChainCreationFailed
            }
            chainExists = true
            actualChainLines = emptyList()
        }

        if (actualChainLines != expectedChainLines) {
            if (jumpCount != 0) return CellularRootPolicyFailure.MangleVerificationFailed
            if (!commandSucceeded("$binary -t mangle -F $MISH_CHAIN")) {
                return CellularRootPolicyFailure.MangleChainCreationFailed
            }
            for (line in expectedChainLines) {
                if (!commandSucceeded("$binary -t mangle $line")) {
                    return CellularRootPolicyFailure.OwnerNewMarkRuleFailed
                }
            }
            snapshot = mangleOutputOrNull(binary) ?: return CellularRootPolicyFailure.MangleVerificationFailed
            chainExists = snapshot.any { it == "-N $MISH_CHAIN" }
            actualChainLines = snapshot.filter { it.startsWith("-A $MISH_CHAIN ") }
            jumpCount = snapshot.count { it == outputJump }
            if (!chainExists || actualChainLines != expectedChainLines || jumpCount != 0) {
                return CellularRootPolicyFailure.MangleVerificationFailed
            }
        }

        if (jumpCount == 0) {
            if (!commandSucceeded("$binary -t mangle $outputJump")) {
                return CellularRootPolicyFailure.OutputJumpCreationFailed
            }
            jumpCount = 1
        }
        while (jumpCount > 1) {
            if (!commandSucceeded("$binary -t mangle ${outputJump.replaceFirst("-A ", "-D ")}")) {
                return CellularRootPolicyFailure.OutputJumpCreationFailed
            }
            jumpCount -= 1
        }

        snapshot = mangleOutputOrNull(binary) ?: return CellularRootPolicyFailure.MangleVerificationFailed
        return if (snapshot.count { it == outputJump } == 1 &&
            snapshot.any { it == "-N $MISH_CHAIN" } &&
            snapshot.filter { it.startsWith("-A $MISH_CHAIN ") } == expectedChainLines
        ) {
            null
        } else {
            CellularRootPolicyFailure.MangleVerificationFailed
        }
    }

    private fun removeLegacySelectors(): Boolean =
        removeExactRule(legacyIpv4SelectorCheck(), legacyIpv4SelectorDelete()) &&
            removeExactRule(legacyIpv6SelectorCheck(), legacyIpv6SelectorDelete())

    private fun verifyFailClosedBase(): Boolean {
        // One fresh post-mutation snapshot is the authoritative verification boundary.
        // Reuse these four observations only inside this pure verification pass; do not cache
        // root state across mutations or across reconcile transactions.
        val snapshot = readVerificationSnapshot() ?: return false
        return verifyMangleFamily(
            snapshot.ipv4Mangle,
            ipv4OwnedChainLines(),
            ipv4OutputJump(),
        ) &&
            verifyMangleFamily(
                snapshot.ipv6Mangle,
                ipv6OwnedChainLines(),
                ipv6OutputJump(),
            ) &&
            snapshot.ipv4Rules.any(::isOwnedIpv4Guard) &&
            snapshot.ipv6Rules.any(::isOwnedIpv6Guard) &&
            ownedIpv4LookupTables(snapshot.ipv4Rules).isEmpty() &&
            auditReservedPolicySpace(
                snapshot.ipv4Rules,
                snapshot.ipv6Rules,
                snapshot.ipv4Mangle,
                snapshot.ipv6Mangle,
            ) == PolicySpaceAudit.Clean
    }

    private fun readVerificationSnapshot(): RootPolicyVerificationSnapshot? {
        val ipv4Rules = ruleOutputOrNull(IPV4_RULE_SHOW) ?: return null
        val ipv6Rules = ruleOutputOrNull(IPV6_RULE_SHOW) ?: return null
        val ipv4Mangle = mangleOutputOrNull(IPTABLES) ?: return null
        val ipv6Mangle = mangleOutputOrNull(IP6TABLES) ?: return null
        return RootPolicyVerificationSnapshot(
            ipv4Rules = ipv4Rules,
            ipv6Rules = ipv6Rules,
            ipv4Mangle = ipv4Mangle,
            ipv6Mangle = ipv6Mangle,
        )
    }

    private fun verifyMangleFamily(
        lines: List<String>,
        expectedChainLines: List<String>,
        outputJump: String,
    ): Boolean = lines.count { it == "-N $MISH_CHAIN" } == 1 &&
        lines.count { it == outputJump } == 1 &&
        lines.filter { it.startsWith("-A $MISH_CHAIN ") } == expectedChainLines

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
                // A mutating root command can reach the kernel while its transport/result becomes
                // non-authoritative. Never replay that uncertain mutation automatically. Instead,
                // take one fresh read-only snapshot and accept detach only if the exact owned jump
                // is now proven absent. If it remains (or cannot be observed), fail closed so the
                // referenced chain and guard stay intact.
                return mangleOutputOrNull(binary)?.none { it == outputJump } == true
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

    private fun ownedIpv4LookupTables(lines: List<String>): List<String> = lines.mapNotNull { line ->
        OWNED_IPV4_LOOKUP_REGEX.matchEntire(line.trim())?.groupValues?.get(1)
    }.filter(RootPolicySnapshot::isSafeTableToken).distinct()

    private fun isOwnedIpv4Guard(line: String): Boolean = OWNED_IPV4_GUARD_REGEX.matches(line.trim())
    private fun isOwnedIpv6Guard(line: String): Boolean = OWNED_IPV6_GUARD_REGEX.matches(line.trim())

    private fun ruleOutputOrNull(command: String): List<String>? = executor.lines(command)

    private fun mangleOutputOrNull(binary: String): List<String>? = executor.mangleLines(binary)

    private fun commandSucceeded(command: String): Boolean = executor.commandSucceeded(command)

    private fun removeExactRule(checkCommand: String, deleteCommand: String): Boolean =
        executor.removeExactRule(checkCommand, deleteCommand, MAX_RECONCILE_PASSES)

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

    private data class RootPolicyVerificationSnapshot(
        val ipv4Rules: List<String>,
        val ipv6Rules: List<String>,
        val ipv4Mangle: List<String>,
        val ipv6Mangle: List<String>,
    )

    private enum class PolicySpaceAudit { Clean, Collision, Unavailable }
    private enum class PolicyIdentityResolution { Selected, Collision, Unavailable }

    private sealed interface ManglePolicyResult {
        data object Enforced : ManglePolicyResult

        data class Failed(
            val failure: CellularRootPolicyFailure,
        ) : ManglePolicyResult
    }

    private data class PolicyIdentity(
        val markHex: String,
        val markValue: ULong,
        val lookupPriority: Int,
        val guardPriority: Int,
    )

    private companion object {
        // Use one small deterministic candidate set; every mark/mask/priority tuple is
        // accepted only after live RPDB/mangle collision audit on the target.
        val RELEASE_POLICY_CANDIDATES = listOf(
            PolicyIdentity("0x200000", 0x200000UL, 9500, 9501),
            PolicyIdentity("0x400000", 0x400000UL, 9520, 9521),
            PolicyIdentity("0x800000", 0x800000UL, 9540, 9541),
            PolicyIdentity("0x1000000", 0x1000000UL, 9560, 9561),
        )
        val DEBUG_POLICY_CANDIDATES = listOf(
            PolicyIdentity("0x2000000", 0x2000000UL, 9580, 9581),
            PolicyIdentity("0x4000000", 0x4000000UL, 9600, 9601),
            PolicyIdentity("0x8000000", 0x8000000UL, 9620, 9621),
            PolicyIdentity("0x10000000", 0x10000000UL, 9640, 9641),
        )
        const val MAX_RECONCILE_PASSES = 8
        const val RELEASE_MISH_CHAIN = "MISH_EGRESS_V1"
        const val DEBUG_MISH_CHAIN = "MISH_DEBUG_EGRESS_V1"
        const val IPTABLES = "iptables"
        const val IP6TABLES = "ip6tables"
        const val IPV4_RULE_SHOW = "ip -4 rule show"
        const val IPV6_RULE_SHOW = "ip -6 rule show"
    }

    private val POLICY_CANDIDATES: List<PolicyIdentity>
        get() = if (debugIsolation) DEBUG_POLICY_CANDIDATES else RELEASE_POLICY_CANDIDATES

    private val LEGACY_MARK_HEX: String
        get() = POLICY_CANDIDATES.first().markHex

    private val MISH_CHAIN: String
        get() = if (debugIsolation) DEBUG_MISH_CHAIN else RELEASE_MISH_CHAIN
}
