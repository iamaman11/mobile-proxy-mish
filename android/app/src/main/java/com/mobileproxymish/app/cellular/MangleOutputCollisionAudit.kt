package com.mobileproxymish.app.cellular

/**
 * Pure parser/auditor for the mangle collision surface owned by [CellularRootPolicy].
 *
 * Collision authority is deliberately narrower than the full mangle table: only OUTPUT and
 * user-defined chains transitively reachable from OUTPUT can compete with PRODUCT outgoing
 * flow classification. PRODUCT-owned MISH material is still validated globally so an
 * unreachable foreign/malformed reference can never be mistaken for owned state.
 */
internal object MangleOutputCollisionAudit {
    internal enum class Result {
        Clean,
        Collision,
        Ambiguous,
    }

    fun audit(
        lines: List<String>,
        allowedProductLines: Set<String>,
        mishChain: String,
        candidateMark: ULong,
    ): Result {
        if (candidateMark == 0UL) return Result.Ambiguous

        val normalized = lines.map(String::trim).filter(String::isNotEmpty)
        if (normalized.any { line -> line.contains(mishChain) && line !in allowedProductLines }) {
            return Result.Collision
        }

        val userChains = linkedSetOf<String>()
        val rulesByChain = linkedMapOf<String, MutableList<List<String>>>()

        for (line in normalized) {
            val tokens = tokenize(line)
            when (tokens.firstOrNull()) {
                "-N" -> {
                    if (tokens.size != 2 || !isSafeChainName(tokens[1])) return Result.Ambiguous
                    if (!userChains.add(tokens[1])) return Result.Ambiguous
                }

                "-A" -> {
                    if (tokens.size < 3 || !isSafeChainName(tokens[1])) return Result.Ambiguous
                    rulesByChain.getOrPut(tokens[1]) { mutableListOf() }.add(tokens)
                }
            }
        }

        val state = mutableMapOf<String, VisitState>()
        fun visit(chain: String): Result {
            when (state[chain]) {
                VisitState.Visiting -> return Result.Ambiguous
                VisitState.Visited -> return Result.Clean
                null -> Unit
            }
            state[chain] = VisitState.Visiting

            for (tokens in rulesByChain[chain].orEmpty()) {
                val line = tokens.joinToString(" ")
                if (line !in allowedProductLines) {
                    when (auditMarkSemantics(tokens, candidateMark)) {
                        Result.Clean -> Unit
                        Result.Collision -> return Result.Collision
                        Result.Ambiguous -> return Result.Ambiguous
                    }
                }

                when (val target = chainTarget(tokens)) {
                    is ChainTarget.Malformed -> return Result.Ambiguous
                    ChainTarget.None -> Unit
                    is ChainTarget.Named -> {
                        if (target.value in userChains) {
                            when (val nested = visit(target.value)) {
                                Result.Clean -> Unit
                                else -> return nested
                            }
                        }
                    }
                }
            }

            state[chain] = VisitState.Visited
            return Result.Clean
        }

        return visit("OUTPUT")
    }

    private fun auditMarkSemantics(tokens: List<String>, candidateMark: ULong): Result {
        var sawKnownMarkOperation = false
        var markTarget = false
        var connmarkTarget = false

        for (index in tokens.indices) {
            when (tokens[index]) {
                "-j", "--jump", "-g", "--goto" -> {
                    val target = tokens.getOrNull(index + 1) ?: return Result.Ambiguous
                    if (target == "MARK") markTarget = true
                    if (target == "CONNMARK") connmarkTarget = true
                }

                "--mark", "--set-xmark", "--set-mark" -> {
                    sawKnownMarkOperation = true
                    val spec = tokens.getOrNull(index + 1) ?: return Result.Ambiguous
                    when (markSpecTouchesCandidate(spec, candidateMark)) {
                        null -> return Result.Ambiguous
                        true -> return Result.Collision
                        false -> Unit
                    }
                }

                "--nfmask", "--ctmask" -> {
                    sawKnownMarkOperation = true
                    val mask = parseUnsigned(tokens.getOrNull(index + 1)) ?: return Result.Ambiguous
                    if (mask > IPV4_FULL_MASK) return Result.Ambiguous
                    if ((mask and candidateMark) != 0UL) return Result.Collision
                }

                "--restore-mark", "--save-mark" -> {
                    sawKnownMarkOperation = true
                    val nfmask = optionMask(tokens, "--nfmask") ?: IPV4_FULL_MASK
                    val ctmask = optionMask(tokens, "--ctmask") ?: IPV4_FULL_MASK
                    if ((nfmask and candidateMark) != 0UL || (ctmask and candidateMark) != 0UL) {
                        return Result.Collision
                    }
                }

                "--and-mark", "--or-mark", "--xor-mark" -> {
                    // These operations can change broad mark state. There is no safe way to
                    // prove candidate-bit non-interference from only the bounded identity bit,
                    // so a reachable foreign use fails this candidate closed.
                    return Result.Collision
                }
            }
        }

        if ((markTarget || connmarkTarget) && !sawKnownMarkOperation) {
            return Result.Ambiguous
        }
        return Result.Clean
    }

    private fun optionMask(tokens: List<String>, option: String): ULong? {
        val index = tokens.indexOf(option)
        if (index < 0) return null
        val value = parseUnsigned(tokens.getOrNull(index + 1)) ?: return INVALID_MASK
        return value.takeIf { it <= IPV4_FULL_MASK } ?: INVALID_MASK
    }

    private fun markSpecTouchesCandidate(spec: String, candidateMark: ULong): Boolean? {
        val parts = spec.split('/', limit = 2)
        if (parts.isEmpty() || parts.size > 2) return null
        val value = parseUnsigned(parts[0]) ?: return null
        val mask = if (parts.size == 2) parseUnsigned(parts[1]) ?: return null else IPV4_FULL_MASK
        if (value > IPV4_FULL_MASK || mask > IPV4_FULL_MASK) return null
        return (mask and candidateMark) != 0UL
    }

    private fun chainTarget(tokens: List<String>): ChainTarget {
        var target: String? = null
        for (index in tokens.indices) {
            if (tokens[index] !in JUMP_OPTIONS) continue
            val candidate = tokens.getOrNull(index + 1) ?: return ChainTarget.Malformed
            if (candidate.startsWith("-")) return ChainTarget.Malformed
            if (target != null && target != candidate) return ChainTarget.Malformed
            target = candidate
        }
        return target?.let { ChainTarget.Named(it) } ?: ChainTarget.None
    }

    private fun tokenize(line: String): List<String> = line.split(WHITESPACE_REGEX)

    private fun parseUnsigned(raw: String?): ULong? {
        if (raw.isNullOrBlank()) return null
        return if (raw.startsWith("0x", ignoreCase = true)) {
            raw.substring(2).takeIf(String::isNotEmpty)?.toULongOrNull(16)
        } else {
            raw.toULongOrNull()
        }
    }

    private fun isSafeChainName(value: String): Boolean =
        value.length in 1..28 && CHAIN_NAME_REGEX.matches(value)

    private enum class VisitState { Visiting, Visited }

    private sealed interface ChainTarget {
        data object None : ChainTarget
        data object Malformed : ChainTarget
        data class Named(val value: String) : ChainTarget
    }

    private val JUMP_OPTIONS = setOf("-j", "--jump", "-g", "--goto")
    private val WHITESPACE_REGEX = Regex("""\s+""")
    private val CHAIN_NAME_REGEX = Regex("""[A-Za-z0-9_.:+-]+""")
    private const val IPV4_FULL_MASK = 0xffffffffUL
    private val INVALID_MASK = ULong.MAX_VALUE
}
