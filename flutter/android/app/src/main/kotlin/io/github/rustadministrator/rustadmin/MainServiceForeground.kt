package io.github.rustadministrator.rustadmin

import android.content.pm.ServiceInfo

/**
 * The foreground service types MainService runs with on Android 14 and later.
 *
 * The service runs before the user has agreed to the screen capture: the app binds it before
 * it asks, and the boot receiver starts it at boot. Android 14 refuses a `mediaProjection`
 * foreground service before that agreement, and Android 15 refuses one started from
 * BOOT_COMPLETED. Until the user agreed the service runs as `specialUse`, a remote access
 * host waiting for connections; once the user agreed it adds `mediaProjection`, before it
 * asks for the projection.
 */
fun mainServiceForegroundTypes(projectionGranted: Boolean): Int =
    if (projectionGranted) {
        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
    } else {
        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
    }
