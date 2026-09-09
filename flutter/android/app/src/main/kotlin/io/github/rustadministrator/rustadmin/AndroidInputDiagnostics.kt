package io.github.rustadministrator.rustadmin

internal enum class AndroidInputFailure(val diagnosticName: String) {
    CLICK("click"),
    DISPATCH_GESTURE("dispatch_gesture"),
    END_GESTURE("end_gesture"),
    HOST_KEY_DECODE("host_key_decode"),
    HOST_KEY_DISPATCH("host_key_dispatch"),
}

internal enum class AndroidInputRejection(val diagnosticName: String) {
    PRESS_COUNT("press_count"),
    TEXT_SIZE("text_size"),
    INVALID_TEXT("invalid_text"),
    HOST_TARGET("host_target"),
    HOST_EDIT("host_edit"),
    HOST_SELECTION("host_selection"),
    HOST_ACTION("host_action"),
    HOST_KEY("host_key"),
}

// Input entrypoints use typed fields rather than formatting nodes, events, or
// exception messages. The sink is injectable without Android runtime objects.
internal class AndroidInputDiagnostics(
    private val emit: (String, String) -> Unit = { level, message ->
        if (level == "error") {
            AndroidDiagnosticLog.error("RustAdmin/Input", message)
        } else {
            AndroidDiagnosticLog.info("RustAdmin/Input", message)
        }
    },
) {
    fun accessibilityConnected() {
        emit("info", "Android input service connected")
    }

    fun rejected(reason: AndroidInputRejection) {
        emit("error", "Android input rejected: reason=${reason.diagnosticName}")
    }

    fun failure(operation: AndroidInputFailure, error: Throwable) {
        emit(
            "error",
            "Android input failure: operation=${operation.diagnosticName}, type=${error.javaClass.simpleName}",
        )
    }

    fun keyboardEnabled(mode: String) {
        emit(
            "info",
            "Android remote keyboard enabled: mode=${diagnosticMode(mode)}, route=fallback-input-connection",
        )
    }

    fun keyboardDisabled(
        mode: String,
        physicalEvents: Long,
        syntheticModifierEvents: Long,
        textFallbacks: Long,
    ) {
        emit(
            "info",
            "Android remote keyboard disabled: mode=${diagnosticMode(mode)}, physical_events=${physicalEvents.coerceAtLeast(0)}, synthetic_modifier_events=${syntheticModifierEvents.coerceAtLeast(0)}, text_fallbacks=${textFallbacks.coerceAtLeast(0)}",
        )
    }

    private fun diagnosticMode(mode: String): String = when (mode) {
        "auto", "text", "physical" -> mode
        else -> "unknown"
    }
}
