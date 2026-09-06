import Foundation

// MARK: - XMLElement

/// The tiny read-only DOM the OOXML parts are read through.
///
/// `XMLDocument` exists on macOS and not on iOS, so the only XML parser in Foundation here is the
/// SAX-style `XMLParser`. A document part is walked in several directions at once — a paragraph's
/// properties, then its runs, then each run's properties — which a streaming parser cannot express,
/// so the events are collected into this tree first.
///
/// ## Prefixes are not namespaces
///
/// Namespace processing is deliberately left off in ``parse(_:)``. With it on, Foundation strips
/// prefixes from attribute names, and `w:id` and `r:id` — which sit on the same element and mean
/// entirely different things — become one key. So qualified names are kept as written, the `xmlns`
/// declarations are resolved into a prefix map on the way past, and ``attribute(_:uri:)`` matches on
/// the namespace when it is given one and on the local name when it is not. A document whose
/// producer chose different prefixes still reads correctly.
public final class XMLElement {

    /// The name as written, prefix included: `w:p`.
    public let qualifiedName: String
    /// The name with any prefix removed: `p`.
    public let localName: String
    /// Attributes keyed by qualified name.
    public private(set) var attributes: [String: String]
    /// Prefix → namespace URI, inherited from every ancestor. `""` is the default namespace.
    public let namespaces: [String: String]
    public private(set) var children: [XMLElement] = []
    /// Character data directly inside this element, with none from its children.
    public private(set) var text: String = ""

    init(qualifiedName: String, attributes: [String: String], namespaces: [String: String]) {
        self.qualifiedName = qualifiedName
        self.localName = Self.local(of: qualifiedName)
        self.attributes = attributes
        self.namespaces = namespaces
    }

    // MARK: - Navigation

    /// Direct children with this local name, whatever prefix they were written with.
    public func elements(_ name: String) -> [XMLElement] {
        children.filter { $0.localName == name }
    }

    /// The first direct child with this local name.
    public func element(_ name: String) -> XMLElement? {
        children.first { $0.localName == name }
    }

    /// The first descendant with this local name, breadth-first.
    public func descendant(_ name: String) -> XMLElement? {
        var queue = children
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if node.localName == name { return node }
            queue.append(contentsOf: node.children)
        }
        return nil
    }

    /// Every descendant with this local name, in document order.
    public func descendants(_ name: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for child in children {
            if child.localName == name { out.append(child) }
            out.append(contentsOf: child.descendants(name))
        }
        return out
    }

    /// All character data under this element, children included.
    public var textContent: String {
        children.reduce(text) { $0 + $1.textContent }
    }

    // MARK: - Attributes

    /// An attribute by local name, preferring the one in `uri` when a namespace is given.
    ///
    /// Falls back to any prefix and then to the bare name, because a package is free to declare a
    /// default namespace and write `val` where another writes `w:val`.
    public func attribute(_ name: String, uri: String? = nil) -> String? {
        if let uri {
            for (key, value) in attributes where Self.local(of: key) == name {
                let prefix = Self.prefix(of: key)
                // An unprefixed attribute is in no namespace at all — never in the default one —
                // so only a declared prefix can match here.
                if !prefix.isEmpty, namespaces[prefix] == uri { return value }
            }
        }
        if let exact = attributes[name] { return exact }
        for (key, value) in attributes where Self.local(of: key) == name { return value }
        return nil
    }

    /// `w:val` on this element, the single most common thing to ask an OOXML element for.
    public var val: String? { attribute("val", uri: OOXMLNamespace.w) }

    /// Whether a toggle property is on.
    ///
    /// `<w:b/>` means bold, and so does `<w:b w:val="true"/>`; `<w:b w:val="false"/>` means the
    /// opposite and is what a run inside a bold style uses to turn it back off. Reading the
    /// element's presence alone bolds text that was explicitly un-bolded.
    public var isToggleOn: Bool {
        guard let value = val else { return true }
        return value.isEmpty || value == "true" || value == "1" || value == "on"
    }

    // MARK: - Parsing

    /// Parses `xml`, or returns nil when it is not well-formed.
    public static func parse(_ xml: String) -> XMLElement? {
        parse(Data(xml.utf8))
    }

    public static func parse(_ data: Data) -> XMLElement? {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        // A part that fails halfway is still worth what it produced: a truncated `numbering.xml`
        // costs the bullet glyph, where refusing the whole document costs the document.
        parser.parse()
        return builder.root
    }
}

// MARK: - Name helpers

extension XMLElement {

    static func local(of qualifiedName: String) -> String {
        guard let colon = qualifiedName.firstIndex(of: ":") else { return qualifiedName }
        return String(qualifiedName[qualifiedName.index(after: colon)...])
    }

    static func prefix(of qualifiedName: String) -> String {
        guard let colon = qualifiedName.firstIndex(of: ":") else { return "" }
        return String(qualifiedName[..<colon])
    }
}

// MARK: - TreeBuilder

/// Turns `XMLParser`'s events into the tree above.
private final class TreeBuilder: NSObject, XMLParserDelegate {

    private(set) var root: XMLElement?
    private var stack: [XMLElement] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String]) {
        var namespaces = stack.last?.namespaces ?? [:]
        var plain: [String: String] = [:]
        for (key, value) in attributeDict {
            if key == "xmlns" {
                namespaces[""] = value
            } else if key.hasPrefix("xmlns:") {
                namespaces[String(key.dropFirst("xmlns:".count))] = value
            } else {
                plain[key] = value
            }
        }

        let element = XMLElement(qualifiedName: qualifiedName ?? elementName,
                                 attributes: plain, namespaces: namespaces)
        stack.last?.append(element)
        stack.append(element)
        if root == nil { root = element }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
        stack.last?.appendText(text)
    }
}

// MARK: - Mutation (parsing only)

private extension XMLElement {

    func append(_ child: XMLElement) { children.append(child) }

    func appendText(_ string: String) { text += string }
}
