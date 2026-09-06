import Foundation

// MARK: - CRC32

/// The checksum every zip entry carries, in both its local header and the central directory.
///
/// A zip whose CRCs are wrong is one Word refuses to open — it validates them before it looks at a
/// single part — so this is not an optional nicety of the writer.
enum CRC32 {

    /// The standard reflected polynomial table (0xEDB88320), built once.
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
