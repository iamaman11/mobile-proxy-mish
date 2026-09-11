#!/usr/bin/env python3
from pathlib import Path

policy = Path('android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRootPolicy.kt')
text = policy.read_text()
old = '''        val materialized = POLICY_CANDIDATES.filter { candidate ->
            val ipv4Matches = ipv4Chain.isEmpty() || ipv4Chain == ipv4OwnedChainLines(candidate)
            val ipv6Matches = ipv6Chain.isEmpty() || ipv6Chain == ipv6OwnedChainLines(candidate)
            (ipv4Chain.isNotEmpty() || ipv6Chain.isNotEmpty()) && ipv4Matches && ipv6Matches
        }
        if (materialized.size > 1) {
            activeIdentity = null
            return PolicyIdentityResolution.Collision
        }
        if ((ipv4Chain.isNotEmpty() || ipv6Chain.isNotEmpty()) && materialized.size != 1) {
            activeIdentity = null
            return PolicyIdentityResolution.Collision
        }

        val preferred = materialized.singleOrNull() ?: activeIdentity
        if (preferred != null) {
            activeIdentity = preferred
            if (auditReservedPolicySpace(ipv4Rules, ipv6Rules, ipv4Mangle, ipv6Mangle) ==
                PolicySpaceAudit.Clean
            ) {
                return PolicyIdentityResolution.Selected
            }
            activeIdentity = null
            return PolicyIdentityResolution.Collision
        }

        for (candidate in POLICY_CANDIDATES) {
            activeIdentity = candidate
            if (auditReservedPolicySpace(ipv4Rules, ipv6Rules, ipv4Mangle, ipv6Mangle) ==
                PolicySpaceAudit.Clean
            ) {
                return PolicyIdentityResolution.Selected
            }
        }
'''
new = '''        // Detached partial state is a recoverable interrupted PRODUCT publication only when
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
            activeIdentity = null
            return PolicyIdentityResolution.Collision
        }

        val candidates = if (hasChainState) compatible else POLICY_CANDIDATES
        val preferred = activeIdentity
        if (preferred != null) {
            if (preferred !in candidates) {
                activeIdentity = null
                return PolicyIdentityResolution.Collision
            }
            activeIdentity = preferred
            if (auditReservedPolicySpace(ipv4Rules, ipv6Rules, ipv4Mangle, ipv6Mangle) ==
                PolicySpaceAudit.Clean
            ) {
                return PolicyIdentityResolution.Selected
            }
            activeIdentity = null
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
'''
assert old in text
policy.write_text(text.replace(old, new))

ui_test = Path('android/app/src/test/java/com/mobileproxymish/app/MainUiStateTest.kt')
text = ui_test.read_text()
text = text.replace('assertTrue(state.overallStatus.contains("not implemented"))', 'assertTrue(state.overallStatus.contains("acceptance pending"))')
old = '        assertEquals("cellular.no_observation", state.cellularReasonCode)\n'
new = old + '        assertEquals("Stopped", state.proxyState)\n        assertEquals(null, state.proxyReasonCode)\n'
assert old in text
ui_test.write_text(text.replace(old, new))

# Keep the architecture comment evidence-based: candidate safety comes from live audit,
# not from a universal claim about Android/netd bit allocation.
text = policy.read_text()
text = text.replace(
    '        // Android 11 netd uses bits 0..20 on the accepted target. Use a small deterministic\n        // candidate set above that range and never dynamically allocate arbitrary policy state.\n',
    '        // Use one small deterministic candidate set; every mark/mask/priority tuple is\n        // accepted only after live RPDB/mangle collision audit on the target.\n',
)
policy.write_text(text)
