package io.github.rustadministrator.rustadmin

import android.content.pm.ServiceInfo
import org.junit.Assert.assertEquals
import org.junit.Test

class MainServiceForegroundTest {
    /** Bound by the app or started at boot, before the user agreed to the screen capture. */
    @Test
    fun beforeTheAgreementTheServiceIsNoMediaProjection() {
        assertEquals(
            0,
            mainServiceForegroundTypes(projectionGranted = false) and
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
        )
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            mainServiceForegroundTypes(projectionGranted = false),
        )
    }

    @Test
    fun afterTheAgreementTheServiceKeepsItsTypeAndAddsMediaProjection() {
        assertEquals(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            mainServiceForegroundTypes(projectionGranted = true),
        )
    }
}
