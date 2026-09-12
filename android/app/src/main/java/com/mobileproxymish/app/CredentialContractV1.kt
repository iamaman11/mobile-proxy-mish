package com.mobileproxymish.app

import java.io.ByteArrayOutputStream
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/**
 * Minimal strict protobuf-v3 wire codec for `contracts/proto/mish/credentials/v1/credentials.proto`.
 *
 * The schema file is the product contract. This adapter intentionally implements only the two
 * tiny messages used by Android/Windows credential persistence and provisioning so production
 * provisioning does not acquire a second package manager or runtime dependency.
 */
internal object CredentialContractV1 {
    const val SCHEMA_VERSION: UInt = 1u

    data class State(
        val version: ULong,
        val revoked: Boolean,
    )

    data class ProvisioningEnvelope(
        val schemaVersion: UInt,
        val credentialVersion: ULong,
        val credentialId: String,
        val challenge: ByteArray,
        val username: String,
        val password: String,
    )

    fun encodeState(version: ULong, revoked: Boolean): ByteArray {
        require(version != 0uL) { "credential version must be non-zero" }
        return ProtoWriter().apply {
            writeVarintField(1, version)
            if (revoked) writeVarintField(2, 1uL)
        }.toByteArray()
    }

    fun decodeState(encoded: ByteArray): State {
        val reader = ProtoReader(encoded)
        var version: ULong? = null
        var revoked = false
        var revokedSeen = false
        while (!reader.exhausted()) {
            val tag = reader.readTag()
            when (tag.fieldNumber) {
                1 -> {
                    require(tag.wireType == WIRE_VARINT && version == null) {
                        "credential state version field is malformed or duplicated"
                    }
                    version = reader.readVarint()
                }
                2 -> {
                    require(tag.wireType == WIRE_VARINT && !revokedSeen) {
                        "credential state revoked field is malformed or duplicated"
                    }
                    revokedSeen = true
                    revoked = when (reader.readVarint()) {
                        0uL -> false
                        1uL -> true
                        else -> error("credential state revoked field is not canonical bool")
                    }
                }
                else -> reader.skip(tag.wireType)
            }
        }
        val exactVersion = requireNotNull(version) { "credential state version field is absent" }
        require(exactVersion != 0uL) { "credential state version must be non-zero" }
        return State(exactVersion, revoked)
    }

    fun encodeProvisioningEnvelope(
        credentialVersion: ULong,
        credentialId: String,
        challenge: ByteArray,
        username: String,
        password: String,
    ): ByteArray {
        require(credentialVersion != 0uL) { "credential version must be non-zero" }
        require(credentialId == "external-proxy-v$credentialVersion") {
            "credential identity/version mismatch"
        }
        require(challenge.size == 32) { "provisioning challenge must be 256-bit" }
        require(USERNAME_PATTERN.matches(username)) { "proxy username shape is invalid" }
        require(PASSWORD_PATTERN.matches(password)) { "proxy password shape is invalid" }

        return ProtoWriter().apply {
            writeVarintField(1, SCHEMA_VERSION.toULong())
            writeVarintField(2, credentialVersion)
            writeBytesField(3, credentialId.toByteArray(StandardCharsets.UTF_8))
            writeBytesField(4, challenge)
            writeBytesField(5, username.toByteArray(StandardCharsets.UTF_8))
            writeBytesField(6, password.toByteArray(StandardCharsets.UTF_8))
        }.toByteArray()
    }

    fun decodeProvisioningEnvelope(encoded: ByteArray): ProvisioningEnvelope {
        val reader = ProtoReader(encoded)
        var schemaVersion: UInt? = null
        var credentialVersion: ULong? = null
        var credentialId: String? = null
        var challenge: ByteArray? = null
        var username: String? = null
        var password: String? = null
        while (!reader.exhausted()) {
            val tag = reader.readTag()
            when (tag.fieldNumber) {
                1 -> {
                    require(tag.wireType == WIRE_VARINT && schemaVersion == null)
                    val raw = reader.readVarint()
                    require(raw <= UInt.MAX_VALUE.toULong())
                    schemaVersion = raw.toUInt()
                }
                2 -> {
                    require(tag.wireType == WIRE_VARINT && credentialVersion == null)
                    credentialVersion = reader.readVarint()
                }
                3 -> {
                    require(tag.wireType == WIRE_LENGTH_DELIMITED && credentialId == null)
                    credentialId = decodeStrictUtf8(reader.readBytes())
                }
                4 -> {
                    require(tag.wireType == WIRE_LENGTH_DELIMITED && challenge == null)
                    challenge = reader.readBytes()
                }
                5 -> {
                    require(tag.wireType == WIRE_LENGTH_DELIMITED && username == null)
                    username = decodeStrictUtf8(reader.readBytes())
                }
                6 -> {
                    require(tag.wireType == WIRE_LENGTH_DELIMITED && password == null)
                    password = decodeStrictUtf8(reader.readBytes())
                }
                else -> reader.skip(tag.wireType)
            }
        }

        val exactSchema = requireNotNull(schemaVersion)
        val exactVersion = requireNotNull(credentialVersion)
        val exactId = requireNotNull(credentialId)
        val exactChallenge = requireNotNull(challenge)
        val exactUsername = requireNotNull(username)
        val exactPassword = requireNotNull(password)
        require(exactSchema == SCHEMA_VERSION) { "unsupported provisioning schema version" }
        require(exactVersion != 0uL) { "credential version must be non-zero" }
        require(exactId == "external-proxy-v$exactVersion") { "credential identity/version mismatch" }
        require(exactChallenge.size == 32) { "provisioning challenge must be 256-bit" }
        require(USERNAME_PATTERN.matches(exactUsername)) { "proxy username shape is invalid" }
        require(PASSWORD_PATTERN.matches(exactPassword)) { "proxy password shape is invalid" }
        return ProvisioningEnvelope(
            schemaVersion = exactSchema,
            credentialVersion = exactVersion,
            credentialId = exactId,
            challenge = exactChallenge,
            username = exactUsername,
            password = exactPassword,
        )
    }

    private fun decodeStrictUtf8(bytes: ByteArray): String = StandardCharsets.UTF_8
        .newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(java.nio.ByteBuffer.wrap(bytes))
        .toString()

    private data class Tag(val fieldNumber: Int, val wireType: Int)

    private class ProtoWriter {
        private val output = ByteArrayOutputStream()

        fun writeVarintField(fieldNumber: Int, value: ULong) {
            writeVarint(((fieldNumber shl 3) or WIRE_VARINT).toULong())
            writeVarint(value)
        }

        fun writeBytesField(fieldNumber: Int, value: ByteArray) {
            writeVarint(((fieldNumber shl 3) or WIRE_LENGTH_DELIMITED).toULong())
            writeVarint(value.size.toULong())
            output.write(value)
        }

        private fun writeVarint(value: ULong) {
            var remaining = value
            while (remaining >= 0x80uL) {
                output.write(((remaining and 0x7fuL).toInt() or 0x80))
                remaining = remaining shr 7
            }
            output.write(remaining.toInt())
        }

        fun toByteArray(): ByteArray = output.toByteArray()
    }

    private class ProtoReader(private val input: ByteArray) {
        private var offset = 0

        fun exhausted(): Boolean = offset == input.size

        fun readTag(): Tag {
            val raw = readVarint()
            require(raw != 0uL && raw <= Int.MAX_VALUE.toULong()) { "protobuf tag is invalid" }
            val field = (raw shr 3).toInt()
            val wire = (raw and 0x07uL).toInt()
            require(field > 0) { "protobuf field number is invalid" }
            return Tag(field, wire)
        }

        fun readVarint(): ULong {
            var result = 0uL
            for (index in 0 until 10) {
                require(offset < input.size) { "protobuf varint is truncated" }
                val byte = input[offset++].toInt() and 0xff
                if (index == 9) {
                    require((byte and 0xfe) == 0) { "protobuf varint overflows uint64" }
                }
                result = result or ((byte and 0x7f).toULong() shl (index * 7))
                if ((byte and 0x80) == 0) return result
            }
            error("protobuf varint is too long")
        }

        fun readBytes(): ByteArray {
            val length = readVarint()
            require(length <= Int.MAX_VALUE.toULong()) { "protobuf field is too large" }
            val count = length.toInt()
            require(count <= input.size - offset) { "protobuf length-delimited field is truncated" }
            val result = input.copyOfRange(offset, offset + count)
            offset += count
            return result
        }

        fun skip(wireType: Int) {
            when (wireType) {
                WIRE_VARINT -> readVarint()
                WIRE_FIXED64 -> advance(8)
                WIRE_LENGTH_DELIMITED -> {
                    val length = readVarint()
                    require(length <= Int.MAX_VALUE.toULong()) { "protobuf field is too large" }
                    advance(length.toInt())
                }
                WIRE_FIXED32 -> advance(4)
                else -> error("unsupported protobuf wire type")
            }
        }

        private fun advance(count: Int) {
            require(count >= 0 && count <= input.size - offset) { "protobuf field is truncated" }
            offset += count
        }
    }

    private const val WIRE_VARINT = 0
    private const val WIRE_FIXED64 = 1
    private const val WIRE_LENGTH_DELIMITED = 2
    private const val WIRE_FIXED32 = 5
    private val USERNAME_PATTERN = Regex("mish-[0-9a-f]{32}")
    private val PASSWORD_PATTERN = Regex("[0-9a-f]{64}")
}
