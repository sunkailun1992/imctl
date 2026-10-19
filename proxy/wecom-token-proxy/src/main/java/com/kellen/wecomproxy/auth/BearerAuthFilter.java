package com.kellen.wecomproxy.auth;

import java.io.IOException;
import java.util.Set;

import org.springframework.web.filter.OncePerRequestFilter;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/**
 * Guards `/wecom/**` (except the callback endpoint WeCom itself calls and the
 * health probe) with the static bearer tokens issued per controller, then the
 * per-token rate limit. The token fingerprint (first 6 chars) is exposed to
 * the controller layer for audit lines; the full token is never logged.
 */
public class BearerAuthFilter extends OncePerRequestFilter {

    public static final String ATTR_TOKEN_FINGERPRINT = "proxy.tokenFingerprint";
    private final Set<String> tokens;
    private final RateLimiter limiter;

    public BearerAuthFilter(Set<String> tokens, RateLimiter limiter) {
        this.tokens = tokens;
        this.limiter = limiter;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String uri = request.getRequestURI();
        return !uri.startsWith("/wecom/") || uri.equals("/wecom/callback");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        String header = request.getHeader("Authorization");
        if (header == null || !header.startsWith("Bearer ")) {
            response.sendError(HttpServletResponse.SC_UNAUTHORIZED, "missing bearer token");
            return;
        }
        String token = header.substring("Bearer ".length()).trim();
        if (token.isEmpty() || !tokens.contains(token)) {
            response.sendError(HttpServletResponse.SC_UNAUTHORIZED, "unknown bearer token");
            return;
        }
        if (!limiter.admit(token)) {
            response.sendError(429, "rate limit exceeded");
            return;
        }
        request.setAttribute(ATTR_TOKEN_FINGERPRINT, token.substring(0, Math.min(6, token.length())));
        chain.doFilter(request, response);
    }
}
