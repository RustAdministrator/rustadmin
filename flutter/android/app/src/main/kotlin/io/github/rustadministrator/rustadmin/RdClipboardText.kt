package io.github.rustadministrator.rustadmin

internal data class RdClipboardText(
    val text: String?,
    val html: String?,
) {
    companion object {
        fun fromItem(
            itemText: CharSequence?,
            itemUri: String?,
            html: String?,
        ): RdClipboardText? {
            val text = selectText(itemText, itemUri)
            if (text == null && html == null) return null
            return RdClipboardText(text, html)
        }

        fun selectText(itemText: CharSequence?, itemUri: String?): String? {
            return itemText?.toString() ?: itemUri?.takeIf(::isWebUrl)
        }

        private fun isWebUrl(uri: String): Boolean {
            val schemeEnd = uri.indexOf("://")
            if (schemeEnd <= 0) return false
            val scheme = uri.substring(0, schemeEnd)
            return scheme.equals("http", ignoreCase = true) ||
                scheme.equals("https", ignoreCase = true)
        }
    }
}
