package com.mobileproxymish.app.cellular

/** Read-only direct-cellular route inspection behind the existing typed root-policy executor. */
internal class DirectCellularRouteInspector(
    private val executor: RootPolicyExecutor,
) {
    fun discoverValidatedIpv4Table(
        iface: String,
        ruleShowCommand: String,
    ): String? {
        val ruleLines = executor.lines(ruleShowCommand) ?: return null
        val tables = RootPolicySnapshot.referencedTables(ruleLines).filter { candidate ->
            val result = executor.observe("ip -4 route show table $candidate default")
            !result.timedOut && result.outputComplete && result.exitCode == 0 &&
                result.stdout.lineSequence()
                    .map(String::trim)
                    .any { line ->
                        (line.startsWith("default ") || line == "default") &&
                            Regex("""(?:^|\s)dev\s+${Regex.escape(iface)}(?:\s|$)""")
                                .containsMatchIn(line)
                    }
        }
        return tables.singleOrNull()
    }

    fun verifyIpv4Path(
        iface: String,
        markHex: String,
    ): Boolean {
        val lookup = executor.observe("ip -4 route get 1.1.1.1 mark $markHex")
        if (lookup.timedOut || !lookup.outputComplete || lookup.exitCode != 0) return false
        return Regex("""(?:^|\s)dev\s+${Regex.escape(iface)}(?:\s|$)""")
            .containsMatchIn(lookup.stdout)
    }
}
