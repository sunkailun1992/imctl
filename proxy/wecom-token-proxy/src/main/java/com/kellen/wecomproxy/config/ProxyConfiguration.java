package com.kellen.wecomproxy.config;

import java.io.IOException;
import java.nio.file.Path;
import java.time.Clock;

import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import com.kellen.wecomproxy.auth.BearerAuthFilter;
import com.kellen.wecomproxy.auth.RateLimiter;
import com.kellen.wecomproxy.callback.CallbackRelay;
import com.kellen.wecomproxy.crypto.WeComCrypto;
import com.kellen.wecomproxy.event.EventPublisher;
import com.kellen.wecomproxy.event.EventSequence;
import com.kellen.wecomproxy.event.LoggingEventPublisher;
import com.kellen.wecomproxy.forward.PathAllowlist;
import com.kellen.wecomproxy.forward.WeComForwarder;
import com.kellen.wecomproxy.mqtt.HiveMqEventPublisher;
import com.kellen.wecomproxy.token.AccessTokenService;
import com.kellen.wecomproxy.token.RestClientWeComHttp;
import com.kellen.wecomproxy.token.WeComHttp;

/** Wiring. Tests override `WeComHttp` and `EventPublisher` beans; everything else is real. */
@Configuration
public class ProxyConfiguration {

    @Bean
    public Clock clock() {
        return Clock.systemUTC();
    }

    @Bean
    @ConditionalOnMissingBean
    public WeComHttp weComHttp(WeComProperties props) {
        return new RestClientWeComHttp(props);
    }

    @Bean
    public AccessTokenService accessTokenService(WeComHttp http, WeComProperties props, Clock clock) {
        return new AccessTokenService(http, props, clock);
    }

    @Bean
    public PathAllowlist pathAllowlist(ProxyProperties props) {
        return new PathAllowlist(props.allowedPathSet());
    }

    @Bean
    public WeComForwarder weComForwarder(WeComHttp http, AccessTokenService tokens) {
        return new WeComForwarder(http, tokens);
    }

    @Bean
    public RateLimiter rateLimiter(ProxyProperties props, Clock clock) {
        return new RateLimiter(props.effectiveRateLimit(), clock);
    }

    @Bean
    public FilterRegistrationBean<BearerAuthFilter> bearerAuthFilter(ProxyProperties props, RateLimiter limiter) {
        FilterRegistrationBean<BearerAuthFilter> reg = new FilterRegistrationBean<>(new BearerAuthFilter(props.tokenSet(), limiter));
        reg.addUrlPatterns("/wecom/*");
        reg.setOrder(1);
        return reg;
    }

    @Bean
    public WeComCrypto weComCrypto(WeComProperties props) {
        String key = props.callbackAesKey();
        // Without a callback key the relay still boots (forwarding works); the callback endpoints then reject everything.
        return new WeComCrypto(props.callbackToken(), key == null || key.length() != 43 ? "0".repeat(43) : key, props.corpId());
    }

    @Bean
    public EventSequence eventSequence(ProxyProperties props) throws IOException {
        return new EventSequence(Path.of(props.dataDir() == null || props.dataDir().isBlank() ? "./data" : props.dataDir()));
    }

    @Bean
    @ConditionalOnMissingBean
    public EventPublisher eventPublisher(MqttProperties props) {
        return props.enabled() ? new HiveMqEventPublisher(props) : new LoggingEventPublisher();
    }

    @Bean
    public CallbackRelay callbackRelay(WeComCrypto crypto, EventSequence sequence, EventPublisher publisher, WeComProperties wecom, MqttProperties mqtt) {
        return new CallbackRelay(crypto, sequence, publisher, wecom.corpId() == null ? "" : wecom.corpId(), mqtt.topicPrefix());
    }
}
