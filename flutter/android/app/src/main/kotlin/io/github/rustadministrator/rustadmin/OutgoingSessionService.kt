package io.github.rustadministrator.rustadmin

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import ffi.FFI
import java.util.concurrent.atomic.AtomicBoolean

class OutgoingSessionService : Service() {
    private data class CleanupSnapshot(
        val sessionId: String,
        val generation: Int,
        val tunnelName: String,
        val ownsTunnel: Boolean,
    )

    private val handler = Handler(Looper.getMainLooper())
    private val lifecycle = OutgoingSessionLifecycle(BACKGROUND_TIMEOUT_MS)
    private var sessionId = ""
    private var sessionGeneration = 0
    private var tunnelName = ""
    private var ownsTunnel = false
    private var sessionPresenceGraceDeadlineMs = 0L
    private var wakeLock: PowerManager.WakeLock? = null
    private var pendingAttachIntent: Intent? = null
    private var recoverOnUnhealthyForeground = false

    private val pollRunnable = object : Runnable {
        override fun run() {
            if (lifecycle.state == OutgoingSessionLifecycleState.CLOSED) return
            if (sessionId.isNotEmpty() &&
                lifecycle.state != OutgoingSessionLifecycleState.EXPIRING
            ) {
                val active = try {
                    FFI.isOutgoingSessionActive(sessionId)
                } catch (error: RuntimeException) {
                    AndroidDiagnosticLog.error(
                        LOG_TAG,
                        "Failed to query outgoing session state",
                        error,
                    )
                    true
                }
                if (active) {
                    sessionPresenceGraceDeadlineMs = 0L
                    if (lifecycle.state == OutgoingSessionLifecycleState.ACTIVE) {
                        recoverOnUnhealthyForeground = false
                    }
                } else if (sessionPresenceGraceDeadlineMs == 0L ||
                    SystemClock.elapsedRealtime() >= sessionPresenceGraceDeadlineMs
                ) {
                    val background =
                        lifecycle.state == OutgoingSessionLifecycleState.BACKGROUND
                    val recover = background || recoverOnUnhealthyForeground
                    beginCleanup(
                        closeRustSession = true,
                        notifyFlutter = recover,
                        reason = when {
                            background -> "background-native-disconnect"
                            recoverOnUnhealthyForeground -> "foreground-unhealthy"
                            else -> "native-disconnect"
                        },
                    )
                    return
                }
            }
            if (lifecycle.shouldExpire(SystemClock.elapsedRealtime())) {
                beginCleanup(
                    closeRustSession = true,
                    notifyFlutter = true,
                    reason = "background-timeout",
                )
                return
            }
            handler.postDelayed(this, SESSION_POLL_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        running.set(true)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ATTACH -> attach(intent)
            ACTION_APP_BACKGROUND -> enterBackground()
            ACTION_APP_FOREGROUND -> enterForeground()
            ACTION_RELEASE -> release(intent)
            ACTION_DISCONNECT_NOW -> beginCleanup(
                closeRustSession = true,
                notifyFlutter = true,
                reason = "notification-disconnect",
            )
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        releaseWakeLock()
        running.set(false)
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        beginCleanup(
            closeRustSession = true,
            notifyFlutter = true,
            reason = "foreground-service-timeout",
        )
    }

    private fun attach(intent: Intent) {
        val newSessionId = intent.getStringExtra(EXTRA_SESSION_ID).orEmpty()
        val newGeneration = intent.getIntExtra(EXTRA_GENERATION, 0)
        if (newSessionId.isEmpty() || newGeneration <= 0) {
            stopSelf()
            return
        }
        if (lifecycle.state == OutgoingSessionLifecycleState.EXPIRING) {
            pendingAttachIntent = Intent(intent)
            AndroidDiagnosticLog.info(
                LOG_TAG,
                "Queued outgoing session attach during cleanup: generation=$newGeneration",
            )
            return
        }
        if (lifecycle.state != OutgoingSessionLifecycleState.CLOSED &&
            sessionId.isNotEmpty() &&
            (sessionId != newSessionId || sessionGeneration != newGeneration)
        ) {
            pendingAttachIntent = Intent(intent)
            beginCleanup(
                closeRustSession = true,
                notifyFlutter = true,
                reason = "session-replaced",
            )
            return
        }
        sessionId = newSessionId
        sessionGeneration = newGeneration
        tunnelName = intent.getStringExtra(EXTRA_TUNNEL_NAME).orEmpty()
        val ownershipRequested = intent.getBooleanExtra(EXTRA_OWNS_TUNNEL, false)
        ownsTunnel = resolveTunnelOwnership(
            ownershipRequested,
            tunnelName,
            WireGuardController::claimPendingTunnel,
        )
        if (ownershipRequested && !ownsTunnel) {
            AndroidDiagnosticLog.warn(
                LOG_TAG,
                "Outgoing session rejected stale WireGuard tunnel ownership",
            )
        }
        sessionPresenceGraceDeadlineMs =
            SystemClock.elapsedRealtime() + SESSION_STARTUP_GRACE_MS
        recoverOnUnhealthyForeground = false
        lifecycle.attach()
        startForeground(NOTIFICATION_ID, buildNotification())
        handler.removeCallbacks(pollRunnable)
        handler.postDelayed(pollRunnable, SESSION_POLL_INTERVAL_MS)
        if (appInBackground.get()) {
            enterBackground()
        }
        AndroidDiagnosticLog.info(
            LOG_TAG,
            "Outgoing session foreground service attached: generation=$sessionGeneration, ownsTunnel=$ownsTunnel",
        )
    }

    private fun enterBackground() {
        if (!lifecycle.enterBackground(SystemClock.elapsedRealtime())) return
        acquireWakeLock()
        updateNotification()
        AndroidDiagnosticLog.info(
            LOG_TAG,
            "Outgoing session background deadline armed: timeoutMs=$BACKGROUND_TIMEOUT_MS",
        )
    }

    private fun enterForeground() {
        if (!lifecycle.enterForeground()) return
        recoverOnUnhealthyForeground = true
        releaseWakeLock()
        updateNotification()
        AndroidDiagnosticLog.info(
            LOG_TAG,
            "Outgoing session returned to foreground before deadline",
        )
    }

    private fun release(intent: Intent) {
        val expectedSessionId = intent.getStringExtra(EXTRA_SESSION_ID).orEmpty()
        val expectedGeneration = intent.getIntExtra(EXTRA_GENERATION, 0)
        if (expectedSessionId != sessionId || expectedGeneration != sessionGeneration) {
            AndroidDiagnosticLog.info(
                LOG_TAG,
                "Ignored stale outgoing session release: session=$expectedSessionId, generation=$expectedGeneration, activeSession=$sessionId, activeGeneration=$sessionGeneration",
            )
            return
        }
        beginCleanup(
            closeRustSession = false,
            notifyFlutter = false,
            reason = "flutter-release",
        )
    }

    private fun beginCleanup(
        closeRustSession: Boolean,
        notifyFlutter: Boolean,
        reason: String,
    ) {
        if (!lifecycle.beginCleanup()) return
        val snapshot = CleanupSnapshot(
            sessionId = sessionId,
            generation = sessionGeneration,
            tunnelName = tunnelName,
            ownsTunnel = ownsTunnel,
        )
        handler.removeCallbacks(pollRunnable)
        releaseWakeLock()
        if (closeRustSession && snapshot.sessionId.isNotEmpty()) {
            try {
                FFI.closeOutgoingSession(snapshot.sessionId)
            } catch (error: RuntimeException) {
                AndroidDiagnosticLog.error(
                    LOG_TAG,
                    "Failed to close outgoing RustAdmin session",
                    error,
                )
            }
        }
        val drainDelay = if (closeRustSession || reason == "flutter-release") {
            SESSION_CLOSE_DRAIN_MS
        } else {
            0L
        }
        handler.postDelayed(
            { finishCleanup(snapshot, notifyFlutter, reason) },
            drainDelay,
        )
    }

    private fun finishCleanup(
        snapshot: CleanupSnapshot,
        notifyFlutter: Boolean,
        reason: String,
    ) {
        val pending = pendingAttachIntent
        pendingAttachIntent = null
        val transferOwnedTunnel = shouldTransferOwnedTunnel(
            currentOwnsTunnel = snapshot.ownsTunnel,
            currentTunnelName = snapshot.tunnelName,
            pendingOwnsTunnel = pending?.getBooleanExtra(EXTRA_OWNS_TUNNEL, false) == true,
            pendingTunnelName = pending?.getStringExtra(EXTRA_TUNNEL_NAME).orEmpty(),
        )
        if (snapshot.ownsTunnel &&
            snapshot.tunnelName.isNotEmpty() &&
            !transferOwnedTunnel
        ) {
            WireGuardController.setTunnelState(this, snapshot.tunnelName, false)
        }
        ownsTunnel = false
        tunnelName = ""
        sessionId = ""
        sessionGeneration = 0
        sessionPresenceGraceDeadlineMs = 0L
        recoverOnUnhealthyForeground = false
        lifecycle.close()
        if (notifyFlutter) {
            MainActivity.flutterMethodChannel?.invokeMethod(
                "outgoing_session_closed",
                mapOf(
                    "session_id" to snapshot.sessionId,
                    "generation" to snapshot.generation,
                    "reason" to reason,
                ),
            )
        }
        AndroidDiagnosticLog.info(
            LOG_TAG,
            "Outgoing session foreground service closed: generation=${snapshot.generation}, reason=$reason",
        )
        if (pending != null) {
            attach(pending)
            if (transferOwnedTunnel && !ownsTunnel) {
                WireGuardController.setTunnelState(this, snapshot.tunnelName, false)
            }
            return
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:outgoing-session-background",
        ).apply {
            setReferenceCounted(false)
            acquire(BACKGROUND_TIMEOUT_MS + WAKE_LOCK_GRACE_MS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                getString(R.string.outgoing_session_channel),
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun buildNotification() = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
        .setSmallIcon(R.mipmap.ic_stat_logo)
        .setContentTitle(getString(R.string.outgoing_session_title))
        .setContentText(
            if (lifecycle.state == OutgoingSessionLifecycleState.BACKGROUND) {
                getString(R.string.outgoing_session_background)
            } else {
                getString(R.string.outgoing_session_active)
            },
        )
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setContentIntent(
            PendingIntent.getActivity(
                this,
                0,
                packageManager.getLaunchIntentForPackage(packageName)
                    ?: Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        .addAction(
            0,
            getString(R.string.outgoing_session_disconnect),
            PendingIntent.getService(
                this,
                1,
                Intent(this, OutgoingSessionService::class.java).setAction(ACTION_DISCONNECT_NOW),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        .build()

    private fun updateNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    companion object {
        private const val LOG_TAG = "RustAdmin/OutgoingSession"
        private const val NOTIFICATION_CHANNEL_ID = "rustadmin_outgoing_session"
        private const val NOTIFICATION_ID = 7118
        private const val BACKGROUND_TIMEOUT_MS = 30_000L
        private const val WAKE_LOCK_GRACE_MS = 5_000L
        private const val SESSION_POLL_INTERVAL_MS = 1_000L
        private const val SESSION_STARTUP_GRACE_MS = 10_000L
        private const val SESSION_CLOSE_DRAIN_MS = 1_200L

        private const val ACTION_ATTACH =
            "io.github.rustadministrator.rustadmin.action.OUTGOING_SESSION_ATTACH"
        private const val ACTION_APP_BACKGROUND =
            "io.github.rustadministrator.rustadmin.action.OUTGOING_SESSION_BACKGROUND"
        private const val ACTION_APP_FOREGROUND =
            "io.github.rustadministrator.rustadmin.action.OUTGOING_SESSION_FOREGROUND"
        private const val ACTION_RELEASE =
            "io.github.rustadministrator.rustadmin.action.OUTGOING_SESSION_RELEASE"
        private const val ACTION_DISCONNECT_NOW =
            "io.github.rustadministrator.rustadmin.action.OUTGOING_SESSION_DISCONNECT"
        private const val EXTRA_SESSION_ID = "session_id"
        private const val EXTRA_GENERATION = "generation"
        private const val EXTRA_TUNNEL_NAME = "tunnel_name"
        private const val EXTRA_OWNS_TUNNEL = "owns_tunnel"

        private val running = AtomicBoolean(false)
        private val appInBackground = AtomicBoolean(false)

        fun attach(
            context: Context,
            sessionId: String,
            generation: Int,
            tunnelName: String,
            ownsTunnel: Boolean,
        ): Boolean {
            if (sessionId.isBlank() || generation <= 0) return false
            val intent = Intent(context, OutgoingSessionService::class.java).apply {
                action = ACTION_ATTACH
                putExtra(EXTRA_SESSION_ID, sessionId)
                putExtra(EXTRA_GENERATION, generation)
                putExtra(EXTRA_TUNNEL_NAME, tunnelName)
                putExtra(EXTRA_OWNS_TUNNEL, ownsTunnel)
            }
            return try {
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (error: RuntimeException) {
                AndroidDiagnosticLog.error(
                    LOG_TAG,
                    "Failed to start outgoing session foreground service",
                    error,
                )
                false
            }
        }

        fun release(context: Context, sessionId: String, generation: Int) {
            if (sessionId.isBlank() || generation <= 0 || !running.get()) return
            try {
                context.startService(
                    Intent(context, OutgoingSessionService::class.java).apply {
                        action = ACTION_RELEASE
                        putExtra(EXTRA_SESSION_ID, sessionId)
                        putExtra(EXTRA_GENERATION, generation)
                    },
                )
            } catch (error: RuntimeException) {
                AndroidDiagnosticLog.error(
                    LOG_TAG,
                    "Failed to send outgoing session release",
                    error,
                )
            }
        }

        fun onAppBackground(context: Context) {
            appInBackground.set(true)
            WireGuardController.cancelPendingTunnel(context)
            sendIfRunning(context, ACTION_APP_BACKGROUND)
        }

        fun onAppForeground(context: Context) {
            appInBackground.set(false)
            sendIfRunning(context, ACTION_APP_FOREGROUND)
        }

        private fun sendIfRunning(context: Context, action: String) {
            if (!running.get()) return
            try {
                context.startService(
                    Intent(context, OutgoingSessionService::class.java).setAction(action),
                )
            } catch (error: RuntimeException) {
                AndroidDiagnosticLog.error(
                    LOG_TAG,
                    "Failed to send outgoing session service action $action",
                    error,
                )
            }
        }
    }
}
