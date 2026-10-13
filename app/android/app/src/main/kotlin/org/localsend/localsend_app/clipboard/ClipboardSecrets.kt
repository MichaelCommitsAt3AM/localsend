package org.localsend.localsend_app.clipboard

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Dedicated app-private, non-backed-up identity file, protected by Android Keystore. */
object ClipboardSecrets {
    private const val ALIAS = "localsend.clipboard.identity.v1"
    private const val MAX_BYTES = 65536
    private val aad = "localsend-clipboard-v1".toByteArray(Charsets.UTF_8)

    private fun file(context: Context) = AtomicFile(File(context.noBackupFilesDir, "clipboard_identity.v1"))
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        check(create) { "Clipboard identity key is missing" }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).setRandomizedEncryptionRequired(true).build())
        return generator.generateKey()
    }

    fun load(context: Context): String? {
        val file = file(context)
        val input = try { file.openRead() } catch (error: java.io.FileNotFoundException) {
            // A missing file is first use; an unreadable existing file is an error.
            if (file.baseFile.exists()) throw error else return null
        }
        val payload = input.use {
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            while (true) {
                val count = it.read(buffer); if (count < 0) break
                require(output.size() + count <= MAX_BYTES)
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
        require(payload.size >= 29 && payload[0] == 1.toByte())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, payload.copyOfRange(1, 13)))
        cipher.updateAAD(aad)
        return cipher.doFinal(payload, 13, payload.size - 13).toString(Charsets.UTF_8)
    }

    fun save(context: Context, value: String) {
        val plaintext = value.toByteArray(Charsets.UTF_8)
        require(plaintext.size <= MAX_BYTES - 64)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true)); cipher.updateAAD(aad)
        val payload = byteArrayOf(1) + cipher.iv + cipher.doFinal(plaintext)
        plaintext.fill(0)
        val file = file(context); val output = file.startWrite()
        try { output.write(payload); file.finishWrite(output) }
        catch (error: Exception) { file.failWrite(output); throw error }
    }
}
