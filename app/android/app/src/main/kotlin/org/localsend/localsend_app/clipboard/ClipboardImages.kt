package org.localsend.localsend_app.clipboard

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import java.io.InputStream

/** Decode bounds before pixel allocation, re-encode to remove source metadata. */
object ClipboardImages {
    const val MAX_BYTES = 8 * 1024 * 1024
    private const val MAX_PIXELS = 16000000L
    fun normalize(input: InputStream): ByteArray {
        val raw = input.readNBytes(MAX_BYTES + 1)
        require(raw.isNotEmpty() && raw.size <= MAX_BYTES)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
        require(bounds.outWidth in 1..16384 && bounds.outHeight in 1..16384 &&
            bounds.outWidth.toLong() * bounds.outHeight <= MAX_PIXELS)
        require(bounds.outMimeType in listOf("image/png", "image/jpeg", "image/webp"))
        val bitmap = BitmapFactory.decodeByteArray(raw, 0, raw.size,
            BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }) ?: error("Invalid image")
        try {
            val output = object : ByteArrayOutputStream() {
                override fun write(bytes: ByteArray, offset: Int, length: Int) {
                    require(count.toLong() + length <= MAX_BYTES); super.write(bytes, offset, length)
                }
                override fun write(value: Int) { require(count < MAX_BYTES); super.write(value) }
            }
            require(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
            return output.toByteArray()
        } finally { bitmap.recycle() }
    }
}
