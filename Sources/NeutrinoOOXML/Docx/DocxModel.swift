import Foundation

// MARK: - DocValue

/// A JSON value held exactly as it was written.
///
/// The document model is ProseMirror JSON, and it carries far more than this module maps: a table
/// cell's `colspan`, a tracked change's author, a layout block's theme. Attributes decode into this
/// rather than into a fixed struct so that everything a newer editor adds survives a read and a
/// write here untouched.
public enum DocValue: Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    /// Kept apart from `double` so `{"level": 1}` re-encodes as `1` rather than `1.0`.
    case int(Int)
    case double(Double)
    case string(String)
    case array([DocValue])
    case object([String: DocValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DocValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: DocValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Unrepresentable JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:          try container.encodeNil()
        case .bool(let v):   try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v):  try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}

// MARK: - DocValue + accessors

public extension DocValue {

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value):    return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default:                 return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value):    return Double(value)
        case .double(let value): return value
        case .string(let value): return Double(value)
        default:                 return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: DocValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [DocValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> DocValue? { objectValue?[key] }

    /// The value as the text an attribute holds — the common case at a call site that has to write
    /// the attribute into XML, where a number and its string are the same thing.
    var text: String? {
        switch self {
        case .string(let value): return value
        case .int(let value):    return String(value)
        case .double(let value): return String(value)
        case .bool(let value):   return value ? "true" : "false"
        default:                 return nil
        }
    }
}

// MARK: - DocMark

/// An inline mark — `bold`, `link`, and the editor's own `trackedInsertion` and friends.
public struct DocMark: Equatable, Hashable, Codable {
    public var type: String
    public var attrs: [String: DocValue]?

    public init(type: String, attrs: [String: DocValue]? = nil) {
        self.type = type
        self.attrs = attrs
    }

    public func attr(_ name: String) -> DocValue? { attrs?[name] }
}

// MARK: - DocNode

/// One node of the ProseMirror document tree.
///
/// Schema-less on purpose: any `type` decodes and unknown attributes survive re-encoding, so a node
/// a newer web release introduces is carried through this module rather than dropped by it.
public struct DocNode: Equatable, Hashable, Codable {
    public var type: String
    public var attrs: [String: DocValue]?
    public var content: [DocNode]?
    public var marks: [DocMark]?
    public var text: String?

    public init(type: String,
                attrs: [String: DocValue]? = nil,
                content: [DocNode]? = nil,
                marks: [DocMark]? = nil,
                text: String? = nil) {
        self.type = type
        self.attrs = attrs
        self.content = content
        self.marks = marks
        self.text = text
    }

    public var children: [DocNode] { content ?? [] }

    public func attr(_ name: String) -> DocValue? { attrs?[name] }

    public func mark(_ name: String) -> DocMark? { marks?.first { $0.type == name } }

    /// Every text node under this one, concatenated.
    public var plainText: String {
        if let text { return text }
        return children.map(\.plainText).joined()
    }

    static func text(_ string: String, marks: [DocMark]? = nil) -> DocNode {
        DocNode(type: "text", marks: marks?.isEmpty == true ? nil : marks, text: string)
    }
}

// MARK: - DocModel

/// A whole document: the ProseMirror tree, plus the layout block stored beside it.
///
/// `meta` is the web editor's `_meta` — page setup, header and footer bands, watermark, background,
/// theme and document properties. It is modelled as a ``DocValue`` rather than a struct because
/// every client stores it verbatim, and a field one of them has not learned about yet must survive
/// the round trip rather than be reset to a default.
public struct DocModel: Equatable, Codable {
    public var doc: DocNode
    public var meta: DocValue?

    public init(doc: DocNode, meta: DocValue? = nil) {
        self.doc = doc
        self.meta = meta
    }

    /// An empty document, which is what a newly created file holds.
    public static let empty = DocModel(doc: DocNode(type: "doc", content: []))

    // MARK: - JSON

    private struct Wrapper: Codable {
        var doc: DocNode
        var meta: DocValue?

        private enum CodingKeys: String, CodingKey {
            case doc
            case meta = "_meta"
        }
    }

    /// Reads the stored envelope: `{ doc, _meta }`, or a bare document node.
    public static func fromJSON(_ json: String) -> DocModel? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        // The wrapper is tried first: `{ doc, _meta }` would otherwise decode as a node with no
        // `type`, which the node decoder rejects only by accident of key names.
        if let wrapper = try? decoder.decode(Wrapper.self, from: data), wrapper.doc.type == "doc" {
            return DocModel(doc: wrapper.doc, meta: wrapper.meta)
        }
        if let node = try? decoder.decode(DocNode.self, from: data), node.type == "doc" {
            return DocModel(doc: node)
        }
        return nil
    }

    /// The envelope, always wrapped, with stable key order.
    ///
    /// Sorted keys because callers compare the bytes: the offline cache decides whether a document
    /// changed by comparing what it encoded, and a dictionary order that varied per process would
    /// make every save look like an edit.
    public func toJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Wrapper(doc: doc, meta: meta))
        return String(decoding: data, as: UTF8.self)
    }
}
