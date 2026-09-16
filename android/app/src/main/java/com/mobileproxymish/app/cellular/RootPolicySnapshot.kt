package com.mobileproxymish.app.cellular

/** Pure parsers/validators for complete RPDB snapshots; owns no root effect or policy lifecycle. */
internal object RootPolicySnapshot {
    private const val IPV4_FULL_MASK = 0xffffffffUL
    private val whitespace = Regex("""\s+""")
    private val tableReference = Regex("""(?:^|\s)(?:lookup|table)\s+([^\s]+)(?:\s|$)""")

    fun isSafeInterfaceName(value: String): Boolean =
        value.length in 1..15 && Regex("""[A-Za-z0-9_.-]+""").matches(value)

    fun isSafeTableToken(value: String): Boolean =
        value.length in 1..32 && Regex("""[A-Za-z0-9_.-]+""").matches(value)

    fun referencedTables(lines: List<String>): List<String> = lines
        .mapNotNull { line ->
            tableReference.find(line)?.groupValues?.get(1)?.takeIf(::isSafeTableToken)
        }
        .distinct()

    fun rpdbLineTouchesReservedMark(line: String, reservedMark: ULong): Boolean {
        val tokens = line.split(whitespace)
        val index = tokens.indexOf("fwmark")
        if (index < 0) return false
        val spec = tokens.getOrNull(index + 1) ?: return true
        return markSpecTouchesReservedBit(spec, reservedMark)
    }

    private fun markSpecTouchesReservedBit(spec: String, reservedMark: ULong): Boolean {
        val parts = spec.split('/', limit = 2)
        val value = parseUnsigned(parts[0]) ?: return true
        val mask = if (parts.size == 2) parseUnsigned(parts[1]) ?: return true else IPV4_FULL_MASK
        if (value > IPV4_FULL_MASK || mask > IPV4_FULL_MASK) return true
        return (mask and reservedMark) != 0UL
    }

    private fun parseUnsigned(raw: String): ULong? = if (raw.startsWith("0x", ignoreCase = true)) {
        raw.substring(2).toULongOrNull(16)
    } else {
        raw.toULongOrNull()
    }
}
