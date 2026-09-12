package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CellularRootPolicyTest {
    @Test
    fun nonAdmittedOwnerBuildsExactFailClosedFlowPolicy() {
        val process = FakePolicyProcess()
        val result = policy(process).reconcile(admitted = false, interfaceName = null)

        assertEquals(CellularRootPolicyResult.FailClosed(), result)
        assertTrue(process.ipv4Guard != null)
        assertTrue(process.ipv6Guard != null)
        assertNull(process.ipv4Lookup)
        assertEquals(FIRST.mark, process.ipv4Guard?.mark)
        assertEquals(FIRST.guard, process.ipv4Guard?.guard)
        assertEquals(1, process.ipv4JumpCount)
        assertEquals(1, process.ipv6JumpCount)
        assertEquals(chainRules(FIRST.mark, ipv4 = true), process.ipv4ChainRules)
        assertEquals(chainRules(FIRST.mark, ipv4 = false), process.ipv6ChainRules)
    }

    @Test
    fun admittedOwnerInstallsValidatedCellularLookupAfterFailClosedBase() {
        val process = FakePolicyProcess()
        val result = policy(process).reconcile(admitted = true, interfaceName = "rmnet_data0")

        assertEquals(CellularRootPolicyResult.Enforced, result)
        assertEquals("1052", process.ipv4Lookup?.table)
        val guardAdd = process.commands.indexOf(guardAdd(FIRST, ipv4 = true))
        val jumpAdd = process.commands.indexOf(IPV4_JUMP_ADD)
        val lookupAdd = process.commands.indexOf(lookupAdd(FIRST, "1052"))
        assertTrue(guardAdd >= 0)
        assertTrue(jumpAdd >= 0)
        assertTrue(lookupAdd >= 0)
        assertTrue(guardAdd < jumpAdd)
        assertTrue(jumpAdd < lookupAdd)
    }

    @Test
    fun ownerLossRemovesLookupButRetainsFlowMarkAndGuard() {
        val process = FakePolicyProcess()
        val policy = policy(process)
        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )

        assertEquals(
            CellularRootPolicyResult.FailClosed(),
            policy.reconcile(admitted = false, interfaceName = null),
        )
        assertNull(process.ipv4Lookup)
        assertEquals(FIRST.mark, process.ipv4Guard?.mark)
        assertEquals(chainRules(FIRST.mark, ipv4 = true), process.ipv4ChainRules)
    }

    @Test
    fun exactForeignFirstCandidateSelectsSecondWithoutDeletingForeignState() {
        val foreign = "-A OUTPUT -j MARK --set-xmark 0x200000/0x200000"
        val process = FakePolicyProcess().apply { foreignIpv4Mangle += foreign }

        val result = policy(process).reconcile(admitted = true, interfaceName = "rmnet_data0")

        assertEquals(CellularRootPolicyResult.Enforced, result)
        assertTrue(process.foreignIpv4Mangle.contains(foreign))
        assertEquals(SECOND.mark, process.ipv4Guard?.mark)
        assertEquals(SECOND.guard, process.ipv4Guard?.guard)
        assertEquals(SECOND.lookup, process.ipv4Lookup?.lookup)
        assertTrue(process.ipv4ChainRules.any { it.contains("${SECOND.mark}/${SECOND.mark}") })
    }

    @Test
    fun foreignFirstPrioritySelectsSecondCandidate() {
        val process = FakePolicyProcess().apply { foreignIpv4Rpdb += "9500: from all lookup main" }

        val result = policy(process).reconcile(admitted = true, interfaceName = "rmnet_data0")

        assertEquals(CellularRootPolicyResult.Enforced, result)
        assertTrue(process.foreignIpv4Rpdb.contains("9500: from all lookup main"))
        assertEquals(SECOND.mark, process.ipv4Guard?.mark)
        assertEquals(SECOND.lookup, process.ipv4Lookup?.lookup)
    }

    @Test
    fun maskOverlapCountsAsCollisionEvenWhenForeignValueIsZero() {
        val process = FakePolicyProcess().apply {
            foreignIpv4Mangle += "-A OUTPUT -j MARK --set-xmark 0x0/0x200000"
        }

        assertEquals(
            CellularRootPolicyResult.FailClosed(),
            policy(process).reconcile(admitted = false, interfaceName = null),
        )
        assertEquals(SECOND.mark, process.ipv4Guard?.mark)
    }

    @Test
    fun everyBoundedCandidateOccupiedFailsClosedWithoutMutation() {
        val process = FakePolicyProcess().apply {
            CANDIDATES.forEach { candidate ->
                foreignIpv4Mangle +=
                    "-A OUTPUT -j MARK --set-xmark ${candidate.mark}/${candidate.mark}"
            }
        }

        val result = policy(process).reconcile(admitted = true, interfaceName = "rmnet_data0")

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.ReservedPolicyCollision),
            result,
        )
        assertNull(process.ipv4Guard)
        assertNull(process.ipv4Lookup)
        assertEquals(0, process.ipv4JumpCount)
        assertEquals(4, process.foreignIpv4Mangle.size)
    }

    @Test
    fun selectedCandidateIsStableAcrossReconcileEvenIfEarlierCollisionDisappears() {
        val process = FakePolicyProcess().apply {
            foreignIpv4Mangle += "-A OUTPUT -j MARK --set-xmark 0x200000/0x200000"
        }
        val policy = policy(process)
        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        process.foreignIpv4Mangle.clear()

        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        assertEquals(SECOND.mark, process.ipv4Guard?.mark)
        assertTrue(process.ipv4ChainRules.any { it.contains("${SECOND.mark}/${SECOND.mark}") })
        assertFalse(process.ipv4ChainRules.any { it.contains("${FIRST.mark}/${FIRST.mark}") })
    }

    @Test
    fun collisionAfterPublicationRevokesLookupAndKeepsSelectedIdentityForRecovery() {
        val process = FakePolicyProcess()
        val policy = policy(process)
        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        val foreign = "-A OUTPUT -j MARK --set-xmark 0x0/${FIRST.mark}"
        process.foreignIpv4Mangle += foreign

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.ReservedPolicyCollision),
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        assertNull(process.ipv4Lookup)
        assertEquals(FIRST.mark, process.ipv4Guard?.mark)
        assertTrue(process.foreignIpv4Mangle.contains(foreign))

        process.foreignIpv4Mangle.clear()
        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        assertEquals(FIRST.mark, process.ipv4Guard?.mark)
        assertEquals(FIRST.lookup, process.ipv4Lookup?.lookup)
    }

    @Test
    fun malformedPublishedChainStillRevokesLookupUsingRetainedIdentity() {
        val process = FakePolicyProcess()
        val policy = policy(process)
        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        process.ipv4ChainRules += "-A $CHAIN -j MARK --set-xmark 0xdead/0xdead"

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.ReservedPolicyCollision),
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        assertNull(process.ipv4Lookup)
        assertEquals(FIRST.mark, process.ipv4Guard?.mark)
        assertTrue(process.ipv4ChainRules.any { it.contains("0xdead/0xdead") })
    }

    @Test
    fun legacyNewOnlySelectorMigratesIntoNamedFlowPolicy() {
        val process = FakePolicyProcess().apply {
            legacyIpv4Selector = true
            legacyIpv6Selector = true
        }

        val result = policy(process).reconcile(admitted = false, interfaceName = null)

        assertEquals(CellularRootPolicyResult.FailClosed(), result)
        assertFalse(process.legacyIpv4Selector)
        assertFalse(process.legacyIpv6Selector)
        assertEquals(FIRST.mark, process.ipv4Guard?.mark)
    }

    @Test
    fun unsafeInterfaceNeverReachesRootShell() {
        val process = FakePolicyProcess()
        val result = policy(process).reconcile(admitted = true, interfaceName = "rmnet0;reboot")

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.InvalidInterface),
            result,
        )
        assertFalse(process.commands.any { it.contains("reboot") })
        assertNull(process.ipv4Lookup)
        assertTrue(process.ipv4Guard != null)
    }

    @Test
    fun incompleteRpdbSnapshotFailsClosedInsteadOfLookingEmpty() {
        val process = FakePolicyProcess().apply { incompleteIpv4RuleReadAt = 2 }

        val result = policy(process).reconcile(admitted = false, interfaceName = null)

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.VerificationFailed),
            result,
        )
        assertNull(process.ipv4Lookup)
        assertNull(process.ipv4Guard)
        assertNull(process.ipv6Guard)
        assertEquals(0, process.ipv4JumpCount)
        assertEquals(0, process.ipv6JumpCount)
    }

    @Test
    fun intentionalCloseRemovesOnlyExactSelectedPolicyAndLeavesForeignRules() {
        val foreign = "-A OUTPUT -j MARK --set-xmark 0x200000/0x200000"
        val process = FakePolicyProcess().apply { foreignIpv4Mangle += foreign }
        val policy = policy(process)
        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )

        policy.close()

        assertNull(process.ipv4Lookup)
        assertNull(process.ipv4Guard)
        assertNull(process.ipv6Guard)
        assertFalse(process.ipv4ChainExists)
        assertFalse(process.ipv6ChainExists)
        assertEquals(0, process.ipv4JumpCount)
        assertEquals(0, process.ipv6JumpCount)
        assertTrue(process.foreignIpv4Mangle.contains(foreign))
    }

    private fun policy(process: FakePolicyProcess): CellularRootPolicy = CellularRootPolicy(
        productUid = UID,
        authority = MagiskRootAuthority.forTesting(process),
        process = process,
    )

    private data class Identity(
        val mark: String,
        val lookup: Int,
        val guard: Int,
    )

    private data class Lookup(
        val mark: String,
        val lookup: Int,
        val table: String,
    )

    private class FakePolicyProcess : RootProcess {
        var ipv4Guard: Identity? = null
        var ipv6Guard: Identity? = null
        var ipv4Lookup: Lookup? = null
        var ipv4ChainExists = false
        var ipv6ChainExists = false
        var ipv4JumpCount = 0
        var ipv6JumpCount = 0
        var legacyIpv4Selector = false
        var legacyIpv6Selector = false
        var incompleteIpv4RuleReadAt: Int? = null
        val ipv4ChainRules = mutableListOf<String>()
        val ipv6ChainRules = mutableListOf<String>()
        val foreignIpv4Rpdb = mutableListOf<String>()
        val foreignIpv6Rpdb = mutableListOf<String>()
        val foreignIpv4Mangle = mutableListOf<String>()
        val foreignIpv6Mangle = mutableListOf<String>()
        val commands = mutableListOf<String>()
        private var ipv4RuleReads = 0

        override fun run(arguments: List<String>): RootProcessResult {
            val command = arguments.last()
            commands += command
            return when {
                command == "id -u" -> ok("0\n")
                command == "ip -4 rule show" -> {
                    ipv4RuleReads += 1
                    RootProcessResult(
                        exitCode = 0,
                        stdout = ipv4Rules(),
                        outputComplete = ipv4RuleReads != incompleteIpv4RuleReadAt,
                    )
                }
                command == "ip -6 rule show" -> ok(ipv6Rules())
                command == "iptables -t mangle -S" -> ok(ipv4Mangle())
                command == "ip6tables -t mangle -S" -> ok(ipv6Mangle())
                command == "iptables -t mangle -N $CHAIN" -> createChain(ipv4 = true)
                command == "ip6tables -t mangle -N $CHAIN" -> createChain(ipv4 = false)
                command == "iptables -t mangle -F $CHAIN" -> flushChain(ipv4 = true)
                command == "ip6tables -t mangle -F $CHAIN" -> flushChain(ipv4 = false)
                command == "iptables -t mangle -X $CHAIN" -> deleteChain(ipv4 = true)
                command == "ip6tables -t mangle -X $CHAIN" -> deleteChain(ipv4 = false)
                command == IPV4_JUMP_ADD -> {
                    if (!ipv4ChainExists) fail() else { ipv4JumpCount += 1; ok() }
                }
                command == IPV6_JUMP_ADD -> {
                    if (!ipv6ChainExists) fail() else { ipv6JumpCount += 1; ok() }
                }
                command == IPV4_JUMP_DELETE -> {
                    if (ipv4JumpCount > 0) { ipv4JumpCount -= 1; ok() } else fail()
                }
                command == IPV6_JUMP_DELETE -> {
                    if (ipv6JumpCount > 0) { ipv6JumpCount -= 1; ok() } else fail()
                }
                command.startsWith("iptables -t mangle -A $CHAIN ") -> appendChain(command, true)
                command.startsWith("ip6tables -t mangle -A $CHAIN ") -> appendChain(command, false)
                command == LEGACY_IPV4_CHECK -> if (legacyIpv4Selector) ok() else fail()
                command == LEGACY_IPV6_CHECK -> if (legacyIpv6Selector) ok() else fail()
                command == LEGACY_IPV4_DELETE -> {
                    if (legacyIpv4Selector) { legacyIpv4Selector = false; ok() } else fail()
                }
                command == LEGACY_IPV6_DELETE -> {
                    if (legacyIpv6Selector) { legacyIpv6Selector = false; ok() } else fail()
                }
                GUARD_ADD_REGEX.matches(command) -> addGuard(command)
                GUARD_DELETE_REGEX.matches(command) -> deleteGuard(command)
                LOOKUP_ADD_REGEX.matches(command) -> addLookup(command)
                LOOKUP_DELETE_REGEX.matches(command) -> deleteLookup(command)
                command == "ip -4 route show table all dev rmnet_data0" -> ok(
                    "default via 10.0.0.1 dev rmnet_data0 table 1052 proto static\n" +
                        "10.0.0.0/30 dev rmnet_data0 table 1052 scope link\n",
                )
                command == "ip -4 route show table 1052 default dev rmnet_data0" ->
                    ok("default via 10.0.0.1 dev rmnet_data0\n")
                ROUTE_GET_REGEX.matches(command) -> routeGet(command)
                else -> fail("unsupported test command: $command")
            }
        }

        private fun addGuard(command: String): RootProcessResult {
            val match = checkNotNull(GUARD_ADD_REGEX.matchEntire(command))
            val family = match.groupValues[1]
            val guard = match.groupValues[2].toInt()
            val mark = match.groupValues[3]
            val identity = Identity(mark, guard - 1, guard)
            if (family == "4") ipv4Guard = identity else ipv6Guard = identity
            return ok()
        }

        private fun deleteGuard(command: String): RootProcessResult {
            val match = checkNotNull(GUARD_DELETE_REGEX.matchEntire(command))
            val family = match.groupValues[1]
            val guard = match.groupValues[2].toInt()
            val mark = match.groupValues[3]
            val current = if (family == "4") ipv4Guard else ipv6Guard
            if (current?.guard != guard || current.mark != mark) return fail()
            if (family == "4") ipv4Guard = null else ipv6Guard = null
            return ok()
        }

        private fun addLookup(command: String): RootProcessResult {
            val match = checkNotNull(LOOKUP_ADD_REGEX.matchEntire(command))
            ipv4Lookup = Lookup(
                mark = match.groupValues[2],
                lookup = match.groupValues[1].toInt(),
                table = match.groupValues[3],
            )
            return ok()
        }

        private fun deleteLookup(command: String): RootProcessResult {
            val match = checkNotNull(LOOKUP_DELETE_REGEX.matchEntire(command))
            val current = ipv4Lookup ?: return fail()
            if (current.lookup != match.groupValues[1].toInt() ||
                current.mark != match.groupValues[2] || current.table != match.groupValues[3]
            ) {
                return fail()
            }
            ipv4Lookup = null
            return ok()
        }

        private fun routeGet(command: String): RootProcessResult {
            val mark = checkNotNull(ROUTE_GET_REGEX.matchEntire(command)).groupValues[1]
            return if (ipv4Lookup?.mark == mark && ipv4Lookup?.table == "1052") {
                ok("1.1.1.1 via 10.0.0.1 dev rmnet_data0 table 1052\n")
            } else {
                fail("RTNETLINK answers: Network is unreachable\n")
            }
        }

        private fun createChain(ipv4: Boolean): RootProcessResult {
            if (ipv4) {
                if (ipv4ChainExists) return fail()
                ipv4ChainExists = true
            } else {
                if (ipv6ChainExists) return fail()
                ipv6ChainExists = true
            }
            return ok()
        }

        private fun flushChain(ipv4: Boolean): RootProcessResult {
            if (ipv4) {
                if (!ipv4ChainExists) return fail()
                ipv4ChainRules.clear()
            } else {
                if (!ipv6ChainExists) return fail()
                ipv6ChainRules.clear()
            }
            return ok()
        }

        private fun deleteChain(ipv4: Boolean): RootProcessResult {
            if (ipv4) {
                if (!ipv4ChainExists || ipv4JumpCount != 0 || ipv4ChainRules.isNotEmpty()) return fail()
                ipv4ChainExists = false
            } else {
                if (!ipv6ChainExists || ipv6JumpCount != 0 || ipv6ChainRules.isNotEmpty()) return fail()
                ipv6ChainExists = false
            }
            return ok()
        }

        private fun appendChain(command: String, ipv4: Boolean): RootProcessResult {
            val prefix = if (ipv4) "iptables -t mangle " else "ip6tables -t mangle "
            val line = command.removePrefix(prefix)
            if (ipv4) {
                if (!ipv4ChainExists) return fail()
                ipv4ChainRules += line
            } else {
                if (!ipv6ChainExists) return fail()
                ipv6ChainRules += line
            }
            return ok()
        }

        private fun ipv4Rules(): String = buildString {
            append("0: from all lookup local\n")
            foreignIpv4Rpdb.forEach { append(it).append('\n') }
            ipv4Lookup?.let {
                append("${it.lookup}: from all fwmark ${it.mark}/${it.mark} lookup ${it.table}\n")
            }
            ipv4Guard?.let {
                append("${it.guard}: from all fwmark ${it.mark}/${it.mark} unreachable\n")
            }
            append("32766: from all lookup main\n")
        }

        private fun ipv6Rules(): String = buildString {
            append("0: from all lookup local\n")
            foreignIpv6Rpdb.forEach { append(it).append('\n') }
            ipv6Guard?.let {
                append("${it.guard}: from all fwmark ${it.mark}/${it.mark} unreachable\n")
            }
            append("32766: from all lookup main\n")
        }

        private fun ipv4Mangle(): String = buildString {
            if (ipv4ChainExists) append("-N $CHAIN\n")
            repeat(ipv4JumpCount) { append(IPV4_JUMP_LINE).append('\n') }
            if (legacyIpv4Selector) append(LEGACY_IPV4_LINE).append('\n')
            ipv4ChainRules.forEach { append(it).append('\n') }
            foreignIpv4Mangle.forEach { append(it).append('\n') }
        }

        private fun ipv6Mangle(): String = buildString {
            if (ipv6ChainExists) append("-N $CHAIN\n")
            repeat(ipv6JumpCount) { append(IPV6_JUMP_LINE).append('\n') }
            if (legacyIpv6Selector) append(LEGACY_IPV6_LINE).append('\n')
            ipv6ChainRules.forEach { append(it).append('\n') }
            foreignIpv6Mangle.forEach { append(it).append('\n') }
        }

        private fun ok(stdout: String = ""): RootProcessResult = RootProcessResult(0, stdout)
        private fun fail(stdout: String = ""): RootProcessResult = RootProcessResult(1, stdout)
    }

    private companion object {
        const val UID = 10123
        const val CHAIN = "MISH_EGRESS_V1"
        val FIRST = Identity("0x200000", 9500, 9501)
        val SECOND = Identity("0x400000", 9520, 9521)
        val CANDIDATES = listOf(
            FIRST,
            SECOND,
            Identity("0x800000", 9540, 9541),
            Identity("0x1000000", 9560, 9561),
        )

        const val IPV4_JUMP_LINE = "-A OUTPUT -m owner --uid-owner 10123 -j MISH_EGRESS_V1"
        const val IPV6_JUMP_LINE = IPV4_JUMP_LINE
        const val IPV4_JUMP_ADD = "iptables -t mangle $IPV4_JUMP_LINE"
        const val IPV6_JUMP_ADD = "ip6tables -t mangle $IPV6_JUMP_LINE"
        const val IPV4_JUMP_DELETE =
            "iptables -t mangle -D OUTPUT -m owner --uid-owner 10123 -j MISH_EGRESS_V1"
        const val IPV6_JUMP_DELETE =
            "ip6tables -t mangle -D OUTPUT -m owner --uid-owner 10123 -j MISH_EGRESS_V1"

        const val LEGACY_IPV4_LINE =
            "-A OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
                "-j MARK --set-xmark 0x200000/0x200000"
        const val LEGACY_IPV6_LINE = LEGACY_IPV4_LINE
        const val LEGACY_IPV4_CHECK =
            "iptables -t mangle -C OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
                "-j MARK --set-xmark 0x200000/0x200000"
        const val LEGACY_IPV6_CHECK =
            "ip6tables -t mangle -C OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
                "-j MARK --set-xmark 0x200000/0x200000"
        const val LEGACY_IPV4_DELETE =
            "iptables -t mangle -D OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
                "-j MARK --set-xmark 0x200000/0x200000"
        const val LEGACY_IPV6_DELETE =
            "ip6tables -t mangle -D OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
                "-j MARK --set-xmark 0x200000/0x200000"

        val GUARD_ADD_REGEX = Regex(
            """ip -([46]) rule add pref (\d+) fwmark (0x[0-9a-f]+)/\3 unreachable""",
        )
        val GUARD_DELETE_REGEX = Regex(
            """ip -([46]) rule del pref (\d+) fwmark (0x[0-9a-f]+)/\3 unreachable""",
        )
        val LOOKUP_ADD_REGEX = Regex(
            """ip -4 rule add pref (\d+) fwmark (0x[0-9a-f]+)/\2 lookup ([A-Za-z0-9_.-]+)""",
        )
        val LOOKUP_DELETE_REGEX = Regex(
            """ip -4 rule del pref (\d+) fwmark (0x[0-9a-f]+)/\2 lookup ([A-Za-z0-9_.-]+)""",
        )
        val ROUTE_GET_REGEX = Regex("""ip -4 route get 1\.1\.1\.1 mark (0x[0-9a-f]+)""")

        fun guardAdd(identity: Identity, ipv4: Boolean): String =
            "ip -${if (ipv4) 4 else 6} rule add pref ${identity.guard} fwmark " +
                "${identity.mark}/${identity.mark} unreachable"

        fun lookupAdd(identity: Identity, table: String): String =
            "ip -4 rule add pref ${identity.lookup} fwmark ${identity.mark}/${identity.mark} lookup $table"

        fun chainRules(mark: String, ipv4: Boolean): List<String> = listOf(
            "-A $CHAIN -d ${if (ipv4) "127.0.0.0/8" else "::1/128"} -j RETURN",
            "-A $CHAIN -j CONNMARK --restore-mark --nfmask $mark --ctmask $mark",
            "-A $CHAIN -m conntrack --ctstate NEW -j MARK --set-xmark $mark/$mark",
            "-A $CHAIN -m conntrack --ctstate NEW -m mark --mark $mark/$mark " +
                "-j CONNMARK --save-mark --nfmask $mark --ctmask $mark",
        )
    }
}
