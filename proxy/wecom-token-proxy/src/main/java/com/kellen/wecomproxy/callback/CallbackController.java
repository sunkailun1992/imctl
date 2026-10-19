package com.kellen.wecomproxy.callback;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** WeCom "接收事件服务器": GET echo verification, POST encrypted events. Unsigned or undecryptable requests are rejected, never relayed. */
@RestController
public class CallbackController {

    private static final Logger log = LoggerFactory.getLogger(CallbackController.class);
    private final CallbackRelay relay;

    public CallbackController(CallbackRelay relay) {
        this.relay = relay;
    }

    @GetMapping(value = "/wecom/callback", produces = MediaType.TEXT_PLAIN_VALUE)
    public ResponseEntity<String> verify(@RequestParam("msg_signature") String signature, @RequestParam String timestamp,
                                         @RequestParam String nonce, @RequestParam String echostr) {
        try {
            String plain = relay.verify(signature, timestamp, nonce, echostr);
            if (plain == null) {
                return ResponseEntity.status(HttpStatus.FORBIDDEN).body("bad signature");
            }
            return ResponseEntity.ok(plain);
        } catch (IllegalArgumentException e) {
            return ResponseEntity.status(HttpStatus.BAD_REQUEST).body("bad echostr");
        }
    }

    @PostMapping(value = "/wecom/callback", produces = MediaType.TEXT_PLAIN_VALUE)
    public ResponseEntity<String> receive(@RequestParam("msg_signature") String signature, @RequestParam String timestamp,
                                          @RequestParam String nonce, @RequestBody String body) {
        try {
            relay.relay(signature, timestamp, nonce, body);
            return ResponseEntity.ok("success");
        } catch (SecurityException e) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN).body("bad signature");
        } catch (IllegalArgumentException e) {
            return ResponseEntity.status(HttpStatus.BAD_REQUEST).body("bad message");
        } catch (Exception e) {
            log.warn("callback relay failed: {}", e.toString());
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body("retry");
        }
    }
}
