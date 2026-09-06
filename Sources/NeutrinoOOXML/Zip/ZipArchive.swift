import Compression
import Foundation

// MARK: - ZipError

public enum ZipError: Error, Equatable {
    /// The bytes are not a zip at all — no end-of-central-directory record.
    case notAnArchive
    /// The central directory names an entry the file does not contain.
    case corruptEntry(String)
    /// An entry uses a compression method other than store or deflate.
    case unsupportedCompression(String)
    case deflateFailed(String)
}

// MARK: - ZipArchive

/// The zip container an OOXML package is: read whole into memory, written whole out of it.
///
/// A `.docx` is a zip, so reading one starts here. There is no third-party dependency behind this
/// and deliberately so — the package this lives in is Foundation-only by design (see
/// `Package.swift`), and a document format that six apps depend on should not hinge on a zip library
/// tracking a moving Swift toolchain. What is implemented is exactly what OOXML uses: stored and
/// deflated entries, no encryption, no zip64, no spanning.
///
/// ## Determinism
///
/// Two writes of the same parts produce byte-identical archives: entries keep the order they were
/// added in, and every local header carries the same fixed DOS timestamp. That matters well beyond
/// tidiness — the offline cache compares stored ciphertext to decide whether a document changed, so
/// an archive that embedded `Date()` would make every no-op save look like an edit.
public struct ZipArchive {

    // MARK: - Entry

    public struct Entry {
        public let name: String
        public let data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    // MARK: - Properties

    /// Part paths in the order they appear in the archive.
    public private(set) var names: [String] = []

    private var parts: [String: Data] = [:]

    // MARK: - Init

    public init() {}

    /// Reads an archive from `bytes`.
    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard let directoryStart = Self.centralDirectoryOffset(in: bytes) else {
            throw ZipError.notAnArchive
        }

        var cursor = directoryStart
        while cursor + 46 <= bytes.count, Self.readUInt32(bytes, cursor) == 0x0201_4B50 {
            let method = Self.readUInt16(bytes, cursor + 10)
            let compressedSize = Int(Self.readUInt32(bytes, cursor + 20))
            let uncompressedSize = Int(Self.readUInt32(bytes, cursor + 24))
            let nameLength = Int(Self.readUInt16(bytes, cursor + 28))
            let extraLength = Int(Self.readUInt16(bytes, cursor + 30))
            let commentLength = Int(Self.readUInt16(bytes, cursor + 32))
            let localOffset = Int(Self.readUInt32(bytes, cursor + 42))

            guard cursor + 46 + nameLength <= bytes.count else { throw ZipError.notAnArchive }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength

            // A directory entry has no content of its own; the parts below it carry their full path.
            if name.hasSuffix("/") { continue }

            let data = try Self.contents(of: name, in: bytes, localHeaderOffset: localOffset,
                                         method: method, compressedSize: compressedSize,
                                         uncompressedSize: uncompressedSize)
            if parts.updateValue(data, forKey: name) == nil { names.append(name) }
        }
    }

    // MARK: - Reading

    /// The bytes of one part, or nil when the archive has no such part.
    public func data(for name: String) -> Data? { parts[name] }

    /// One part decoded as UTF-8 text, which is what every XML part in a package is.
    public func text(for name: String) -> String? {
        guard let data = parts[name] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func contains(_ name: String) -> Bool { parts[name] != nil }

    // MARK: - Writing

    /// Adds or replaces a part. A replaced part keeps its position in the archive.
    public mutating func set(_ name: String, data: Data) {
        if parts.updateValue(data, forKey: name) == nil { names.append(name) }
    }

    public mutating func set(_ name: String, text: String) {
        set(name, data: Data(text.utf8))
    }

    public mutating func remove(_ name: String) {
        guard parts.removeValue(forKey: name) != nil else { return }
        names.removeAll { $0 == name }
    }

    /// Serialises the archive.
    ///
    /// Every part is deflated. `[Content_Types].xml` is written first when it is present, because
    /// the OPC specification requires it to be the package's first part.
    public func serialized() throws -> Data {
        var ordered = names
        if let index = ordered.firstIndex(of: OOXMLPackage.contentTypesPart), index != 0 {
            ordered.remove(at: index)
            ordered.insert(OOXMLPackage.contentTypesPart, at: 0)
        }

        var output = [UInt8]()
        var directory = [UInt8]()
        var count = 0

        for name in ordered {
            guard let part = parts[name] else { continue }
            let plain = [UInt8](part)
            let crc = CRC32.checksum(plain)
            let deflated = try Self.deflate(plain, name: name)
            // Deflating incompressible bytes (a JPEG, say) can make them larger; storing those is
            // both smaller and faster to read back.
            let stored = deflated.count >= plain.count
            let payload = stored ? plain : deflated
            let method: UInt16 = stored ? 0 : 8

            let nameBytes = [UInt8](name.utf8)
            let localOffset = output.count

            output += Self.uint32(0x0403_4B50)          // local file header signature
            output += Self.uint16(20)                   // version needed to extract
            output += Self.uint16(0)                    // flags
            output += Self.uint16(method)
            output += Self.uint16(Self.dosTime)
            output += Self.uint16(Self.dosDate)
            output += Self.uint32(crc)
            output += Self.uint32(UInt32(payload.count))
            output += Self.uint32(UInt32(plain.count))
            output += Self.uint16(UInt16(nameBytes.count))
            output += Self.uint16(0)                    // extra field length
            output += nameBytes
            output += payload

            directory += Self.uint32(0x0201_4B50)       // central directory header signature
            directory += Self.uint16(20)                // version made by
            directory += Self.uint16(20)                // version needed
            directory += Self.uint16(0)                 // flags
            directory += Self.uint16(method)
            directory += Self.uint16(Self.dosTime)
            directory += Self.uint16(Self.dosDate)
            directory += Self.uint32(crc)
            directory += Self.uint32(UInt32(payload.count))
            directory += Self.uint32(UInt32(plain.count))
            directory += Self.uint16(UInt16(nameBytes.count))
            directory += Self.uint16(0)                 // extra
            directory += Self.uint16(0)                 // comment
            directory += Self.uint16(0)                 // disk number
            directory += Self.uint16(0)                 // internal attributes
            directory += Self.uint32(0)                 // external attributes
            directory += Self.uint32(UInt32(localOffset))
            directory += nameBytes

            count += 1
        }

        let directoryOffset = output.count
        output += directory
        output += Self.uint32(0x0605_4B50)              // end of central directory signature
        output += Self.uint16(0)                        // this disk
        output += Self.uint16(0)                        // disk with the directory
        output += Self.uint16(UInt16(count))
        output += Self.uint16(UInt16(count))
        output += Self.uint32(UInt32(directory.count))
        output += Self.uint32(UInt32(directoryOffset))
        output += Self.uint16(0)                        // comment length

        return Data(output)
    }

    // MARK: - Sniffing

    /// A zip's local file header. The cheapest possible way to reject bytes that cannot be a package.
    public static func looksLikeArchive(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(4))
        return bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04
    }

    // MARK: - Private

    /// MS-DOS 1980-01-01 00:00:00, the earliest timestamp the format can express — see the note on
    /// determinism above.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x0021

    private static func contents(of name: String, in bytes: [UInt8], localHeaderOffset: Int,
                                 method: UInt16, compressedSize: Int,
                                 uncompressedSize: Int) throws -> Data {
        guard localHeaderOffset + 30 <= bytes.count,
              readUInt32(bytes, localHeaderOffset) == 0x0403_4B50 else {
            throw ZipError.corruptEntry(name)
        }
        // The local header's own name and extra lengths are read rather than the directory's: the
        // two are allowed to differ, and it is the local one that says where the bytes start.
        let nameLength = Int(readUInt16(bytes, localHeaderOffset + 26))
        let extraLength = Int(readUInt16(bytes, localHeaderOffset + 28))
        let start = localHeaderOffset + 30 + nameLength + extraLength
        guard start + compressedSize <= bytes.count else { throw ZipError.corruptEntry(name) }
        let payload = Array(bytes[start..<(start + compressedSize)])

        switch method {
        case 0:  return Data(payload)
        case 8:  return Data(try inflate(payload, expecting: uncompressedSize, name: name))
        default: throw ZipError.unsupportedCompression(name)
        }
    }

    /// Raw DEFLATE, which is what `COMPRESSION_ZLIB` means here: Apple's zlib codec reads and writes
    /// the bare RFC 1951 stream, with none of the RFC 1950 framing the name suggests. That is
    /// precisely what a zip entry holds.
    private static func deflate(_ bytes: [UInt8], name: String) throws -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        // Deflate can expand incompressible input; the caller falls back to storing when it does,
        // so the buffer only has to be large enough to notice.
        let capacity = bytes.count + (bytes.count / 2) + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let written = bytes.withUnsafeBufferPointer { input in
            compression_encode_buffer(&output, capacity, input.baseAddress!, bytes.count,
                                      nil, COMPRESSION_ZLIB)
        }
        // Zero means the codec could not fit the result in the buffer — for input this
        // incompressible the caller wants the stored copy anyway, so say so by returning something
        // longer than the input rather than failing the whole write.
        guard written > 0 else { return bytes + [0] }
        return Array(output[0..<written])
    }

    private static func inflate(_ bytes: [UInt8], expecting size: Int, name: String) throws -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        // The central directory states the uncompressed size, so the buffer is exact. A stated size
        // of zero (a streamed entry) is not something OOXML produces, but it costs one guess to
        // tolerate rather than to reject.
        var capacity = size > 0 ? size : max(bytes.count * 8, 1024)
        for _ in 0..<8 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = bytes.withUnsafeBufferPointer { input in
                compression_decode_buffer(&output, capacity, input.baseAddress!, bytes.count,
                                          nil, COMPRESSION_ZLIB)
            }
            if written > 0 && (written < capacity || size > 0) {
                return Array(output[0..<written])
            }
            if written == 0 { break }
            capacity *= 4
        }
        throw ZipError.corruptEntry(name)
    }

    /// The offset the central directory starts at, found by scanning back for the EOCD record.
    private static func centralDirectoryOffset(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        // The record is 22 bytes plus a comment of up to 65535 — no further back than that.
        let earliest = max(0, bytes.count - 22 - 65535)
        var index = bytes.count - 22
        while index >= earliest {
            if readUInt32(bytes, index) == 0x0605_4B50 {
                let offset = Int(readUInt32(bytes, index + 16))
                return offset <= bytes.count ? offset : nil
            }
            index -= 1
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func uint16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}
