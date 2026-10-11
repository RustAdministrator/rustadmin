package io.github.rustadministrator.rustadmin

import android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
import android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
import android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar
import android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CodecFormatsTest {
    @Test
    fun planarAndSemiPlanarAreYuv420Output() {
        assertTrue(hasYuv420Output(intArrayOf(COLOR_FormatYUV420Planar)))
        assertTrue(hasYuv420Output(intArrayOf(COLOR_FormatSurface, COLOR_FormatYUV420SemiPlanar)))
    }

    @Test
    fun flexibleAloneIsNotYuv420Output() {
        assertFalse(hasYuv420Output(intArrayOf(COLOR_FormatYUV420Flexible)))
        assertFalse(hasYuv420Output(intArrayOf()))
    }

    @Test
    fun surfaceOnlyDecoderStaysListed() {
        assertTrue(isDecoderListable(intArrayOf(COLOR_FormatSurface)))
        assertTrue(isDecoderListable(intArrayOf(COLOR_FormatYUV420Planar)))
        assertFalse(isDecoderListable(intArrayOf(COLOR_FormatYUV420Flexible)))
    }
}
