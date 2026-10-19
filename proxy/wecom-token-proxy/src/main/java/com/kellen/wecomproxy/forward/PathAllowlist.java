package com.kellen.wecomproxy.forward;

import java.util.Set;

/** Only the interfaces the design uses are reachable; anything else is 404 before a token is even looked at. */
public class PathAllowlist {

    private final Set<String> allowed;

    public PathAllowlist(Set<String> allowed) {
        this.allowed = allowed;
    }

    /** Normalises `/a/b/` to `a/b`; rejects traversal and query smuggling. */
    public static String normalize(String path) {
        if (path == null) {
            return "";
        }
        String p = path.strip();
        while (p.startsWith("/")) {
            p = p.substring(1);
        }
        while (p.endsWith("/")) {
            p = p.substring(0, p.length() - 1);
        }
        if (p.contains("..") || p.contains("?") || p.contains("#") || p.contains("//")) {
            return "";
        }
        return p;
    }

    public boolean allows(String path) {
        String p = normalize(path);
        return !p.isEmpty() && allowed.contains(p);
    }
}
