package com.kellen.wecomproxy.util;

import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The little JSON the proxy needs: read flat fields from WeCom envelopes and
 * build the callback event object. Keeping this dependency-free means a
 * Jackson major-version change in the platform cannot break the relay.
 */
public final class JsonMini {

    private JsonMini() {
    }

    /** Value of a top-level string or number field, or null. Good enough for WeCom envelopes (flat, no nesting on these keys). */
    public static String field(String json, String key) {
        if (json == null) {
            return null;
        }
        Matcher m = Pattern.compile("\"" + Pattern.quote(key) + "\"\\s*:\\s*(\"((?:\\\\.|[^\"\\\\])*)\"|(-?\\d+(?:\\.\\d+)?))").matcher(json);
        if (!m.find()) {
            return null;
        }
        return m.group(2) != null ? unescape(m.group(2)) : m.group(3);
    }

    public static Integer intField(String json, String key) {
        String v = field(json, key);
        if (v == null) {
            return null;
        }
        try {
            return Integer.parseInt(v.contains(".") ? v.substring(0, v.indexOf('.')) : v);
        } catch (NumberFormatException e) {
            return null;
        }
    }

    public static String quote(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                default -> {
                    if (c < 0x20) {
                        b.append(String.format("\\u%04x", (int) c));
                    } else {
                        b.append(c);
                    }
                }
            }
        }
        return b.append('"').toString();
    }

    /** `{"k":"v",...}` with string values, keys in the map's iteration order. */
    public static String object(Map<String, String> fields) {
        StringBuilder b = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, String> e : fields.entrySet()) {
            if (!first) {
                b.append(',');
            }
            first = false;
            b.append(quote(e.getKey())).append(':').append(e.getValue() == null ? "null" : quote(e.getValue()));
        }
        return b.append('}').toString();
    }

    private static String unescape(String s) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\\' && i + 1 < s.length()) {
                char n = s.charAt(++i);
                switch (n) {
                    case 'n' -> b.append('\n');
                    case 'r' -> b.append('\r');
                    case 't' -> b.append('\t');
                    case 'u' -> {
                        if (i + 4 < s.length()) {
                            b.append((char) Integer.parseInt(s.substring(i + 1, i + 5), 16));
                            i += 4;
                        }
                    }
                    default -> b.append(n);
                }
            } else {
                b.append(c);
            }
        }
        return b.toString();
    }
}
