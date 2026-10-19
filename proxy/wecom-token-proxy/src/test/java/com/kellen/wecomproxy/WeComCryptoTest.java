package com.kellen.wecomproxy;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.security.SecureRandom;
import java.util.Base64;

import org.junit.jupiter.api.Test;

import com.kellen.wecomproxy.crypto.WeComCrypto;

class WeComCryptoTest {

    static String randomAesKey() {
        byte[] raw = new byte[32];
        new SecureRandom().nextBytes(raw);
        return Base64.getEncoder().encodeToString(raw).substring(0, 43);
    }

    @Test
    void roundTripAndSignature() {
        String key = randomAesKey();
        WeComCrypto crypto = new WeComCrypto("tok", key, "wwcorp");
        String xml = "<xml><ToUserName><![CDATA[wwcorp]]></ToUserName><Event><![CDATA[change_external_contact]]></Event></xml>";
        String encrypted = crypto.encrypt(xml);
        assertThat(crypto.decrypt(encrypted)).isEqualTo(xml);
        String sig = crypto.signature("1700000000", "nonce1", encrypted);
        assertThat(sig).hasSize(40);
        assertThat(crypto.verify(sig, "1700000000", "nonce1", encrypted)).isTrue();
        assertThat(crypto.verify(sig, "1700000001", "nonce1", encrypted)).isFalse();
        assertThat(crypto.verify(null, "1700000000", "nonce1", encrypted)).isFalse();
    }

    @Test
    void receiveIdMismatchAndGarbageFailClosed() {
        String key = randomAesKey();
        String other = new WeComCrypto("tok", key, "wwother").encrypt("hello");
        assertThatThrownBy(() -> new WeComCrypto("tok", key, "wwcorp").decrypt(other)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new WeComCrypto("tok", key, "wwcorp").decrypt("not-base64!!")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new WeComCrypto("tok", "short", "wwcorp")).isInstanceOf(IllegalArgumentException.class);
    }
}
