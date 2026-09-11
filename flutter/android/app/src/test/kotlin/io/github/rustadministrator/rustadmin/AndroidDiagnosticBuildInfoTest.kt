package io.github.rustadministrator.rustadmin

import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidDiagnosticBuildInfoTest {
    @Test fun reportsLoadedLibraryWithoutAssumingApkRevision() {
        assertEquals(
            "nativeVersion=2.0.5\nnativeRevision=164\nnativeBuildDate=2026-09-10\n",
            AndroidDiagnosticBuildInfo.read {
                "nativeVersion=2.0.5\nnativeRevision=164\nnativeBuildDate=2026-09-10\nignored=value\n"
            }
        )
    }

    @Test fun missingOldNativeSymbolIsExplicitlyUnavailable() {
        val unavailable = "nativeVersion=unavailable\nnativeRevision=unavailable\nnativeBuildDate=unavailable\n"
        assertEquals(unavailable, AndroidDiagnosticBuildInfo.read { throw UnsatisfiedLinkError() })
        assertEquals(unavailable, AndroidDiagnosticBuildInfo.read { "nativeVersion=2.0.5\n" })
        assertEquals(unavailable, AndroidDiagnosticBuildInfo.read { "" })
    }
}
