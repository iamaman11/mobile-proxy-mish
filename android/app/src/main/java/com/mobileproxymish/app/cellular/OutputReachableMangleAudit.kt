package com.mobileproxymish.app.cellular

import java.util.ArrayDeque

/**
 * Candidate-specific collision audit for the mangle paths that can actually process PRODUCT
 * OUTPUT traffic. The full table snapshot is still retained by [CellularRootPolicy] for exact
 * PRODUCT ownership, publication and cleanup verification; this helper only narrows foreign
 * MARK/CONNMARK collision authority to OUTPUT and transitively reachable user chains.
 */
internal object OutputReachableMangleAudit {
    private val builtInChains = setOf("PREROUTING", "INPUT", "FORWARD", "OUTPUT", "POSTROUTING")
    private const val fullMarkMask = 0xffffffffUL

    fun hasReservedCollision(
        lines: List<String>,
        allowedProductLines: Set<String>,
        reservedMark: ULong,
        ownedChain: String,
    ): Boolean {
        val snapshot = lines.map(String::trim).filter(String::isNotEmpty)

        if (snapshot.any { line ->
                referencesOwnedChain(line, ownedChain) && line !in allowedProductLines
            }
        ) {
            return true
        }

        val declaredUserChains = mutableSetOf<String>()
        val rulesByChain = mutableMapOf<String, MutableList<String>>()
        for (line in snapshot) {
            val tokens = tokens(line)
            when (tokens.firstOrNull()) {
                "-N" -> {
                    val name = tokens.getOrNull(1)
                    if (name != null && tokens.size == 2) declaredUserChains += name
                }
                "-A" -> {
                    val chain = tokens.getOrNull(1) ?: continue
                    rulesByChain.getOrPut(chain) { mutableListOf() } += line
                }
            }
        }

        val reachable = ArrayDeque<String>()
        val visited = mutableSetOf<String>()
        reachable.addLast("OUTPUT")

        while (reachable.isNotEmpty()) {
            val chain = reachable.removeFirst()
            if (!visited.add(chain)) continue

            for (line in rulesByChain[chain].orEmpty()) {
                val parsed = parseReachableRule(line, reservedMark)
                if (parsed.ambiguous) return true
                if (line !in allowedProductLines && parsed.touchesReservedMark) return true

                val target = parsed.transferTarget ?: continue
                if (target in declaredUserChains) {
                    reachable.addLast(target)
                } else if (target !in builtInChains && rulesByChain.containsKey(target)) {
                    return true
                }
            }
        }

        return false
    }

    private fun referencesOwnedChain(line: String, ownedChain: String): Boolean {
        val tokens = tokens(line)
        if (tokens.size >= 2 && tokens[0] == "-N" && tokens[1] == ownedChain) return true
        if (tokens.size >= 2 && tokens[0] == "-A" && tokens[1] == ownedChain) return true
        for (index in tokens.indices) {
            if (tokens[index] in transferOptions && tokens.getOrNull(index + 1) == ownedChain) {
                return true
            }
        }
        return false
    }

    private fun parseReachableRule(line: String, reservedMark: ULong): ParsedRule {
        val tokens = tokens(line)
        if (tokens.size < 2 || tokens[0] != "-A") return ParsedRule(ambiguous = true)

        var transferTarget: String? = null
        var transferCount = 0
        var markSemanticsSeen = false
        var markMatchDeclared = false
        var touchesReservedMark = false
        var restoreOrSave = false
        var nfMaskSeen = false
        var ctMaskSeen = false

        var index = 2
        while (index < tokens.size) {
            val token = tokens[index]
            when (token) {
                "-j", "--jump", "-g", "--goto" -> {
                    transferCount += 1
                    val target = tokens.getOrNull(index + 1)
                    if (target == null || target.startsWith("-")) {
                        return ParsedRule(ambiguous = true)
                    }
                    transferTarget = target
                    index += 2
                    continue
                }
                "-m", "--match" -> {
                    val match = tokens.getOrNull(index + 1)
                    if (match == null || match.startsWith("-")) {
                        return ParsedRule(ambiguous = true)
                    }
                    if (match == "mark") markMatchDeclared = true
                    index += 2
                    continue
                }
                "--set-xmark", "--set-mark", "--mark" -> {
                    markSemanticsSeen = true
                    val spec = tokens.getOrNull(index + 1)
                        ?: return ParsedRule(ambiguous = true)
                    val mask = parseMarkMask(spec) ?: return ParsedRule(ambiguous = true)
                    if ((mask and reservedMark) != 0UL) touchesReservedMark = true
                    index += 2
                    continue
                }
                "--and-mark" -> {
                    markSemanticsSeen = true
                    val value = parseMarkValue(tokens.getOrNull(index + 1))
                        ?: return ParsedRule(ambiguous = true)
                    val affectedMask = value.inv() and fullMarkMask
                    if ((affectedMask and reservedMark) != 0UL) touchesReservedMark = true
                    index += 2
                    continue
                }
                "--or-mark", "--xor-mark" -> {
                    markSemanticsSeen = true
                    val value = parseMarkValue(tokens.getOrNull(index + 1))
                        ?: return ParsedRule(ambiguous = true)
                    if ((value and reservedMark) != 0UL) touchesReservedMark = true
                    index += 2
                    continue
                }
                "--restore-mark", "--save-mark" -> {
                    markSemanticsSeen = true
                    restoreOrSave = true
                }
                "--nfmask" -> {
                    markSemanticsSeen = true
                    nfMaskSeen = true
                    val mask = parseMarkValue(tokens.getOrNull(index + 1))
                        ?: return ParsedRule(ambiguous = true)
                    if ((mask and reservedMark) != 0UL) touchesReservedMark = true
                    index += 2
                    continue
                }
                "--ctmask" -> {
                    markSemanticsSeen = true
                    ctMaskSeen = true
                    val mask = parseMarkValue(tokens.getOrNull(index + 1))
                        ?: return ParsedRule(ambiguous = true)
                    if ((mask and reservedMark) != 0UL) touchesReservedMark = true
                    index += 2
                    continue
                }
            }
            index += 1
        }

        if (transferCount > 1) return ParsedRule(ambiguous = true)

        val markTarget = transferTarget == "MARK" || transferTarget == "CONNMARK"
        if (markTarget && !markSemanticsSeen) return ParsedRule(ambiguous = true)
        if (markMatchDeclared && tokens.none { it == "--mark" }) return ParsedRule(ambiguous = true)
        if (restoreOrSave && (!nfMaskSeen || !ctMaskSeen)) touchesReservedMark = true

        return ParsedRule(
            transferTarget = transferTarget,
            touchesReservedMark = touchesReservedMark,
        )
    }

    private fun parseMarkMask(spec: String): ULong? {
        val parts = spec.split('/', limit = 2)
        val value = parseMarkValue(parts[0]) ?: return null
        if (value > fullMarkMask) return null
        val mask = if (parts.size == 2) parseMarkValue(parts[1]) ?: return null else fullMarkMask
        return mask.takeIf { it <= fullMarkMask }
    }

    private fun parseMarkValue(raw: String?): ULong? {
        if (raw.isNullOrEmpty() || raw.startsWith("-")) return null
        val value = if (raw.startsWith("0x", ignoreCase = true)) {
            raw.substring(2).toULongOrNull(16)
        } else {
            raw.toULongOrNull()
        }
        return value?.takeIf { it <= fullMarkMask }
    }

    private fun tokens(line: String): List<String> =
        line.trim().split(Regex("""\s+""")).filter(String::isNotEmpty)

    private data class ParsedRule(
        val transferTarget: String? = null,
        val touchesReservedMark: Boolean = false,
        val ambiguous: Boolean = false,
    )

    private val transferOptions = setOf("-j", "--jump", "-g", "--goto")
}
