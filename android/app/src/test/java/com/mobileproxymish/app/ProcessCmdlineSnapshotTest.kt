package com.mobileproxymish.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProcessCmdlineSnapshotTest {
    @Test
    fun digestMatchesExactNulDelimitedProcCmdlineSnapshot() {
        val argv = listOf(
            "/data/app/lib/libsingbox.so",
            "run",
            "-c",
            "/data/user/0/com.mobileproxymish.app.debug/no_backup/proxy-runtime/" +
                "sing-box-abcdefghijklmnopqrstuvwx.json",
        )

        val expected = "8dc057cc3570d8ccd2d951d4bc7c6ba3c557c4cbf31761f4ca38c483b5f038ff"
        assertTrue(procCmdlineSnapshotMatchesDigest(argv, expected))
    }

    @Test
    fun mixedOrMalformedSnapshotFailsClosed() {
        val argv = listOf("/data/app/lib/libsingbox.so", "run", "-c", "/owned/config.json")
        val digest = procCmdlineSha256(argv)

        assertTrue(procCmdlineSnapshotMatchesDigest(argv, digest))
        assertFalse(procCmdlineSnapshotMatchesDigest(argv + "unexpected", digest))
        assertFalse(procCmdlineSnapshotMatchesDigest(argv, "not-a-sha256"))
    }
}
