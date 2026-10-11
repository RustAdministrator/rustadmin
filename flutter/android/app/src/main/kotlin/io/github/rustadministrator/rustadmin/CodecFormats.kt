package io.github.rustadministrator.rustadmin

import android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
import android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar
import android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar

/**
 * A decoder can hand frames to the native side as raw YUV420 only through the
 * planar or semi-planar formats; the flexible format is a request for a
 * `Image` output and is not readable from a `ByteBuffer`.
 */
internal fun hasYuv420Output(colorFormats: IntArray): Boolean =
    colorFormats.any {
        it == COLOR_FormatYUV420Planar || it == COLOR_FormatYUV420SemiPlanar
    }

/** A decoder is listed when it can produce YUV420 buffers or render to a surface. */
internal fun isDecoderListable(colorFormats: IntArray): Boolean =
    hasYuv420Output(colorFormats) || colorFormats.contains(COLOR_FormatSurface)
