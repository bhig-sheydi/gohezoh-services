package org.gohezohservices.kwikparsel;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.UUID;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Per-install alarm credential. Secret is encrypted by a key that never leaves Android Keystore. */
final class AdminAlarmStore {
    private static final String PREFS = "admin_alarm_v1";
    private static final String KEY_ALIAS = "kwik_parsel_admin_alarm_v1";

    static final class Credential {
        final String deviceId;
        final String secret;
        final boolean registered;

        Credential(String deviceId, String secret, boolean registered) {
            this.deviceId = deviceId;
            this.secret = secret;
            this.registered = registered;
        }
    }

    private AdminAlarmStore() { }

    static synchronized Credential getOrCreate(Context context) throws Exception {
        Credential current = read(context);
        if (current != null) return current;
        byte[] random = new byte[32];
        new SecureRandom().nextBytes(random);
        String secret = Base64.getUrlEncoder().withoutPadding().encodeToString(random);
        String deviceId = UUID.randomUUID().toString();
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey());
        byte[] encrypted = cipher.doFinal(secret.getBytes(StandardCharsets.UTF_8));
        prefs(context).edit()
            .putString("device_id", deviceId)
            .putString("iv", Base64.getEncoder().encodeToString(cipher.getIV()))
            .putString("secret", Base64.getEncoder().encodeToString(encrypted))
            .putBoolean("registered", false)
            .apply();
        return new Credential(deviceId, secret, false);
    }

    static synchronized Credential read(Context context) {
        SharedPreferences stored = prefs(context);
        String deviceId = stored.getString("device_id", null);
        String iv = stored.getString("iv", null);
        String encrypted = stored.getString("secret", null);
        if (deviceId == null || iv == null || encrypted == null) return null;
        try {
            UUID.fromString(deviceId);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(),
                new GCMParameterSpec(128, Base64.getDecoder().decode(iv)));
            String secret = new String(cipher.doFinal(Base64.getDecoder().decode(encrypted)), StandardCharsets.UTF_8);
            if (!secret.matches("[A-Za-z0-9_-]{43}")) throw new IllegalStateException("Invalid device credential");
            return new Credential(deviceId, secret, stored.getBoolean("registered", false));
        } catch (Exception error) {
            stored.edit().clear().apply();
            return null;
        }
    }

    static synchronized boolean markRegistered(Context context) {
        Credential current = read(context);
        if (current == null) return false;
        prefs(context).edit().putBoolean("registered", true).apply();
        return true;
    }

    static synchronized void clear(Context context) {
        prefs(context).edit().clear().apply();
        try {
            KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
            keyStore.load(null);
            keyStore.deleteEntry(KEY_ALIAS);
        } catch (Exception ignored) { /* Old key can be replaced on the next opt-in. */ }
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static SecretKey getOrCreateKey() throws Exception {
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        KeyStore.Entry existing = keyStore.getEntry(KEY_ALIAS, null);
        if (existing instanceof KeyStore.SecretKeyEntry)
            return ((KeyStore.SecretKeyEntry) existing).getSecretKey();
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build());
        return generator.generateKey();
    }
}
