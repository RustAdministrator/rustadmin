package io.github.rustadministrator.rustadmin

internal object AndroidDiagnosticBuildInfo {
    fun read(nativeInfo: () -> String): String {
        return try {
            val value = nativeInfo()
            val fields = value.lineSequence().mapNotNull { line ->
                val parts = line.split('=', limit = 2)
                if (parts.size == 2) parts[0] to parts[1].trim() else null
            }.toMap()
            val keys = listOf("nativeVersion", "nativeRevision", "nativeBuildDate")
            if (keys.any { fields[it].isNullOrEmpty() }) unavailable()
            else keys.joinToString(separator = "\n", postfix = "\n") { "$it=${fields[it]}" }
        } catch (_: LinkageError) {
            unavailable()
        } catch (_: RuntimeException) {
            unavailable()
        }
    }

    private fun unavailable() =
        "nativeVersion=unavailable\nnativeRevision=unavailable\nnativeBuildDate=unavailable\n"
}
