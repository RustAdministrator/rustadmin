package io.github.rustadministrator.rustadmin

internal enum class OutgoingSessionLifecycleState {
    ACTIVE,
    BACKGROUND,
    EXPIRING,
    CLOSED,
}

internal class OutgoingSessionLifecycle(
    private val backgroundTimeoutMs: Long,
) {
    var state = OutgoingSessionLifecycleState.CLOSED
        private set

    private var backgroundDeadlineMs = 0L

    fun attach() {
        state = OutgoingSessionLifecycleState.ACTIVE
        backgroundDeadlineMs = 0L
    }

    fun enterBackground(nowMs: Long): Boolean {
        if (state != OutgoingSessionLifecycleState.ACTIVE) return false
        state = OutgoingSessionLifecycleState.BACKGROUND
        backgroundDeadlineMs = nowMs + backgroundTimeoutMs
        return true
    }

    fun enterForeground(): Boolean {
        if (state != OutgoingSessionLifecycleState.BACKGROUND) return false
        state = OutgoingSessionLifecycleState.ACTIVE
        backgroundDeadlineMs = 0L
        return true
    }

    fun shouldExpire(nowMs: Long): Boolean {
        return state == OutgoingSessionLifecycleState.BACKGROUND &&
            backgroundDeadlineMs > 0L &&
            nowMs >= backgroundDeadlineMs
    }

    fun beginCleanup(): Boolean {
        if (state == OutgoingSessionLifecycleState.EXPIRING ||
            state == OutgoingSessionLifecycleState.CLOSED
        ) {
            return false
        }
        state = OutgoingSessionLifecycleState.EXPIRING
        backgroundDeadlineMs = 0L
        return true
    }

    fun close() {
        state = OutgoingSessionLifecycleState.CLOSED
        backgroundDeadlineMs = 0L
    }
}

internal fun resolveTunnelOwnership(
    requested: Boolean,
    tunnelName: String,
    claimPending: (String) -> Boolean,
): Boolean {
    return requested && tunnelName.isNotBlank() && claimPending(tunnelName)
}
