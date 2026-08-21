package io.github.rustadministrator.rustadmin

import android.util.Log
import ffi.FFI

internal object AndroidDiagnosticLog {
    fun info(tag: String, message: String) {
        Log.i(tag, message)
        persist("info", tag, message)
    }

    fun warn(tag: String, message: String) {
        Log.w(tag, message)
        persist("warn", tag, message)
    }

    fun error(tag: String, message: String, error: RuntimeException) {
        Log.e(tag, message, error)
        persist(
            "error",
            tag,
            "$message: ${error.javaClass.simpleName}: ${error.message.orEmpty()}",
        )
    }

    private fun persist(level: String, tag: String, message: String) {
        try {
            FFI.logDiagnostic(level, "$tag: $message")
        } catch (error: LinkageError) {
            Log.w("RustAdmin/Diagnostics", "Native diagnostic bridge is unavailable", error)
        } catch (error: RuntimeException) {
            Log.w("RustAdmin/Diagnostics", "Native diagnostic write failed", error)
        }
    }
}
