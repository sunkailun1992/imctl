package com.kellen.wecomproxy.callback;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;

import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

/** Top-level children of a WeCom XML message as name → text (CDATA included); nested elements are flattened with dots. External entities are disabled. */
public final class XmlFlattener {

    private XmlFlattener() {
    }

    public static Map<String, String> flatten(String xml) {
        try {
            DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
            f.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
            f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            f.setExpandEntityReferences(false);
            DocumentBuilder b = f.newDocumentBuilder();
            Document doc = b.parse(new ByteArrayInputStream(xml.getBytes(StandardCharsets.UTF_8)));
            Map<String, String> out = new LinkedHashMap<>();
            walk(doc.getDocumentElement(), "", out);
            return out;
        } catch (Exception e) {
            throw new IllegalArgumentException("bad xml", e);
        }
    }

    private static void walk(Element element, String prefix, Map<String, String> out) {
        NodeList children = element.getChildNodes();
        boolean hasElementChild = false;
        for (int i = 0; i < children.getLength(); i++) {
            Node n = children.item(i);
            if (n.getNodeType() == Node.ELEMENT_NODE) {
                hasElementChild = true;
                Element child = (Element) n;
                String name = prefix.isEmpty() ? child.getTagName() : prefix + "." + child.getTagName();
                walk(child, name, out);
            }
        }
        if (!hasElementChild && !prefix.isEmpty()) {
            out.put(prefix, element.getTextContent());
        }
    }
}
