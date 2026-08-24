package com.loomup.client.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.loomup.client.RefreshTokenStore
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** AES-GCM token blob encrypted by a non-exportable Android Keystore key. */
class AndroidRefreshTokenStore(
    context: Context,
    private val account: String,
) : RefreshTokenStore {
    private val preferences = context.applicationContext.getSharedPreferences(
        "loomup.secure.refresh",
        Context.MODE_PRIVATE,
    )
    private val alias = "loomup.refresh.$account"

    override fun loadRefreshToken(): String? {
        val encoded = preferences.getString(account, null) ?: return null
        return try {
            val blob = Base64.decode(encoded, Base64.NO_WRAP)
            require(blob.size > 12) { "invalid encrypted refresh token" }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob.copyOfRange(0, 12)))
            String(cipher.doFinal(blob.copyOfRange(12, blob.size)), Charsets.UTF_8)
        } catch (_: Exception) {
            // Auto Backup can restore the encrypted preference without its
            // device-bound Keystore key; key invalidation and tampering have
            // the same safe outcome. Discard the unusable token and require
            // normal sign-in instead of crashing application startup.
            preferences.edit().remove(account).apply()
            runCatching {
                KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias)
            }
            null
        }
    }

    override fun saveRefreshToken(token: String?) {
        if (token == null) {
            preferences.edit().remove(account).apply()
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val blob = cipher.iv + cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        preferences.edit().putString(account, Base64.encodeToString(blob, Base64.NO_WRAP)).apply()
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }
}
