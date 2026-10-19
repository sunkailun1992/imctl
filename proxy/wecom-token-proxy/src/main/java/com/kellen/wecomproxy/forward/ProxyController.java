package com.kellen.wecomproxy.forward;

import java.nio.charset.StandardCharsets;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import com.kellen.wecomproxy.auth.BearerAuthFilter;
import com.kellen.wecomproxy.config.WeComProperties;
import com.kellen.wecomproxy.token.AccessTokenService;
import com.kellen.wecomproxy.token.WeComHttp;
import com.kellen.wecomproxy.util.JsonMini;

import jakarta.servlet.http.HttpServletRequest;

/** `POST /wecom/{path}` passthrough and `GET /healthz`. Audit lines carry no bodies. */
@RestController
public class ProxyController {

    private static final Logger audit = LoggerFactory.getLogger("proxy.audit");
    private final PathAllowlist allowlist;
    private final WeComForwarder forwarder;
    private final AccessTokenService tokens;
    private final WeComProperties wecom;

    public ProxyController(PathAllowlist allowlist, WeComForwarder forwarder, AccessTokenService tokens, WeComProperties wecom) {
        this.allowlist = allowlist;
        this.forwarder = forwarder;
        this.tokens = tokens;
        this.wecom = wecom;
    }

    @PostMapping(value = "/wecom/**")
    public ResponseEntity<byte[]> forward(HttpServletRequest request, @RequestBody(required = false) byte[] body) {
        String path = PathAllowlist.normalize(request.getRequestURI().substring("/wecom/".length()));
        String fingerprint = String.valueOf(request.getAttribute(BearerAuthFilter.ATTR_TOKEN_FINGERPRINT));
        long started = System.nanoTime();
        if (!allowlist.allows(path)) {
            audit.info("token={} path={} status=404 errcode=- ms=0", fingerprint, path);
            return ResponseEntity.status(HttpStatus.NOT_FOUND).contentType(MediaType.APPLICATION_JSON)
                    .body("{\"error\":\"path not allowed\"}".getBytes(StandardCharsets.UTF_8));
        }
        try {
            WeComHttp.Response r = forwarder.forward(path, body == null ? new byte[0] : body, request.getContentType());
            Integer errcode = JsonMini.intField(r.body(), "errcode");
            audit.info("token={} path={} status={} errcode={} ms={}", fingerprint, path, r.status(), errcode, (System.nanoTime() - started) / 1_000_000);
            if (r.status() < 200 || r.status() >= 300) {
                return ResponseEntity.status(HttpStatus.BAD_GATEWAY).contentType(MediaType.APPLICATION_JSON)
                        .body(("{\"error\":\"wecom HTTP " + r.status() + "\"}").getBytes(StandardCharsets.UTF_8));
            }
            return ResponseEntity.ok().contentType(MediaType.APPLICATION_JSON).body(r.body().getBytes(StandardCharsets.UTF_8));
        } catch (AccessTokenService.TokenUnavailableException e) {
            audit.info("token={} path={} status=503 errcode=- ms={} reason={}", fingerprint, path, (System.nanoTime() - started) / 1_000_000, e.getMessage());
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).contentType(MediaType.APPLICATION_JSON)
                    .body("{\"error\":\"no access_token\"}".getBytes(StandardCharsets.UTF_8));
        } catch (RuntimeException e) {
            audit.info("token={} path={} status=502 errcode=- ms={} reason={}", fingerprint, path, (System.nanoTime() - started) / 1_000_000, e.getClass().getSimpleName());
            return ResponseEntity.status(HttpStatus.BAD_GATEWAY).contentType(MediaType.APPLICATION_JSON)
                    .body("{\"error\":\"wecom unreachable\"}".getBytes(StandardCharsets.UTF_8));
        }
    }

    @GetMapping(value = "/healthz", produces = "application/json")
    public String health() {
        return "{\"status\":\"ok\",\"tokenCached\":" + tokens.cached() + ",\"corpId\":" + JsonMini.quote(wecom.corpId() == null ? "" : wecom.corpId()) + "}";
    }
}
