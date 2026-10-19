package com.kellen.wecomproxy.crypto;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;

import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * WeCom callback crypto (WXBizMsgCrypt): SHA-1 signature over the sorted
 * token/timestamp/nonce/ciphertext, AES-256-CBC with the key derived from
 * EncodingAESKey, IV = first 16 key bytes, PKCS#7 padding to 32-byte blocks,
 * plaintext = 16 random bytes + 4-byte big-endian length + message + receive id.
 * Verification and receive-id checks fail closed.
 */
public final class WeComCrypto {

    private static final int BLOCK = 32;
    private final String token;
    private final byte[] key;
    private final String receiveId;
    private final SecureRandom random = new SecureRandom();

    public WeComCrypto(String token, String encodingAesKey, String receiveId) {
        if (encodingAesKey == null || encodingAesKey.length() != 43) {
            throw new IllegalArgumentException("EncodingAESKey must be 43 characters");
        }
        this.token = token == null ? "" : token;
        this.key = Base64.getDecoder().decode(encodingAesKey + "=");
        this.receiveId = receiveId == null ? "" : receiveId;
    }

    public String signature(String timestamp, String nonce, String encrypted) {
        String[] parts = {token, timestamp, nonce, encrypted};
        Arrays.sort(parts);
        try {
            MessageDigest sha1 = MessageDigest.getInstance("SHA-1");
            byte[] digest = sha1.digest(String.join("", parts).getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder();
            for (byte b : digest) {
                hex.append(String.format("%02x", b));
            }
            return hex.toString();
        } catch (Exception e) {
            throw new IllegalStateException("SHA-1 unavailable", e);
        }
    }

    public boolean verify(String msgSignature, String timestamp, String nonce, String encrypted) {
        return msgSignature != null && msgSignature.equalsIgnoreCase(signature(timestamp, nonce, encrypted));
    }

    public String encrypt(String plaintext) {
        try {
            byte[] text = plaintext.getBytes(StandardCharsets.UTF_8);
            byte[] rid = receiveId.getBytes(StandardCharsets.UTF_8);
            byte[] rnd = new byte[16];
            random.nextBytes(rnd);
            ByteBuffer buf = ByteBuffer.allocate(16 + 4 + text.length + rid.length);
            buf.put(rnd).putInt(text.length).put(text).put(rid);
            byte[] padded = pad(buf.array());
            Cipher cipher = Cipher.getInstance("AES/CBC/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new IvParameterSpec(Arrays.copyOf(key, 16)));
            return Base64.getEncoder().encodeToString(cipher.doFinal(padded));
        } catch (Exception e) {
            throw new IllegalStateException("encrypt failed", e);
        }
    }

    public String decrypt(String encrypted) {
        byte[] plain;
        try {
            Cipher cipher = Cipher.getInstance("AES/CBC/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new IvParameterSpec(Arrays.copyOf(key, 16)));
            plain = unpad(cipher.doFinal(Base64.getDecoder().decode(encrypted)));
        } catch (Exception e) {
            throw new IllegalArgumentException("decrypt failed", e);
        }
        if (plain.length < 20) {
            throw new IllegalArgumentException("ciphertext too short");
        }
        int len = ByteBuffer.wrap(plain, 16, 4).getInt();
        if (len < 0 || 20 + len > plain.length) {
            throw new IllegalArgumentException("bad message length");
        }
        String text = new String(plain, 20, len, StandardCharsets.UTF_8);
        String rid = new String(plain, 20 + len, plain.length - 20 - len, StandardCharsets.UTF_8);
        if (!receiveId.isEmpty() && !receiveId.equals(rid)) {
            throw new IllegalArgumentException("receive id mismatch");
        }
        return text;
    }

    private static byte[] pad(byte[] data) {
        int amount = BLOCK - (data.length % BLOCK);
        byte[] out = Arrays.copyOf(data, data.length + amount);
        Arrays.fill(out, data.length, out.length, (byte) amount);
        return out;
    }

    private static byte[] unpad(byte[] data) {
        int amount = data[data.length - 1] & 0xff;
        if (amount < 1 || amount > BLOCK || amount > data.length) {
            throw new IllegalArgumentException("bad padding");
        }
        return Arrays.copyOf(data, data.length - amount);
    }
}
