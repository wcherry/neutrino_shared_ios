import XCTest
import NeutrinoCore
import NeutrinoAuth
@testable import NeutrinoCrypto

/// The recovery kit is a wire format, not a presentation choice: a kit written down here is typed
/// into the web app to restore the account. So the expected strings below are not hand-computed —
/// they were produced by the web implementation (`exportRecoveryKit` in
/// `web/packages/e2e-crypto/src/recoveryKit.ts`) for the same secret keys. If a change to this port
/// breaks them, kits minted on iOS have stopped being restorable anywhere else.
final class RecoveryKitTests: XCTestCase {

    /// 00 01 02 … 1f
    private let secretKey1 = Data((0..<32).map { UInt8($0) })
    /// ff fe fd … e0
    private let secretKey2 = Data((0..<32).map { UInt8(255 - $0) })

    // MARK: - Cross-implementation fixtures

    func testSingleEntryKitMatchesTheWebImplementation() {
        let kit = RecoveryKit.export(entries: [
            RecoveryKit.Entry(version: 1, secretKey: secretKey1),
        ])

        XCTAssertEqual(kit, """
        9R0G-2001-000G-40R4-0M30-E209-185G-R38E
        1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG-0
        """)
    }

    /// A rotated account: the kit carries every version, because a document sealed to version 1
    /// needs version 1.
    func testRotatedKeyringKitMatchesTheWebImplementation() {
        let kit = RecoveryKit.export(entries: [
            RecoveryKit.Entry(version: 1, secretKey: secretKey1, isRetired: true),
            RecoveryKit.Entry(version: 2, secretKey: secretKey2),
        ])

        XCTAssertEqual(kit, """
        9R0G-4001-000G-40R4-0M30-E209-185G-R38E
        1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG-2002
        ZZZF-VZ7V-ZBWZ-HXZP-YQTF-7WQH-Y3QY-XVFC
        XFNE-KT77-WVJY-9RZ2-W7G0-0
        """)
    }

    // MARK: - Shape

    /// Crockford base32 drops I, L, O and U so the common misreadings cannot happen at all. A kit
    /// containing one would be copied back wrong by whoever normalises it.
    func testKitUsesTheCrockfordAlphabetOnly() {
        let kit = RecoveryKit.export(entries: [RecoveryKit.Entry(version: 1, secretKey: secretKey2)])
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHJKMNPQRSTVWXYZ-\n")

        XCTAssertNil(kit.rangeOfCharacter(from: allowed.inverted))
    }

    /// Grouped in fours, eight groups to a line — this is copied by eye, and an unbroken run of 61
    /// characters is where transcription errors come from.
    func testKitIsGroupedInFoursEightToALine() {
        let kit = RecoveryKit.export(entries: [RecoveryKit.Entry(version: 1, secretKey: secretKey1)])
        let lines = kit.split(separator: "\n")

        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let groups = line.split(separator: "-")
            XCTAssertLessThanOrEqual(groups.count, 8)
            // Every group but the very last is a full four characters.
            for group in groups.dropLast() where line == lines.first {
                XCTAssertEqual(group.count, 4)
            }
        }
        // 3 header bytes + 35 per entry = 38 bytes → 61 base32 characters.
        XCTAssertEqual(kit.filter { $0 != "-" && $0 != "\n" }.count, 61)
    }

    // MARK: - Import

    /// The other direction of the same interop claim: a kit the web app printed has to restore
    /// here, which is the whole point of someone carrying one to a phone.
    func testAKitFromTheWebImplementationIsRestored() throws {
        let entries = try RecoveryKit.import("""
        9R0G-4001-000G-40R4-0M30-E209-185G-R38E
        1W81-24GK-2GAH-C5RR-34D1-P70X-3RFG-2002
        ZZZF-VZ7V-ZBWZ-HXZP-YQTF-7WQH-Y3QY-XVFC
        XFNE-KT77-WVJY-9RZ2-W7G0-0
        """)

        XCTAssertEqual(entries, [
            RecoveryKit.Entry(version: 1, secretKey: secretKey1, isRetired: true),
            RecoveryKit.Entry(version: 2, secretKey: secretKey2),
        ])
    }

    func testExportAndImportRoundTrip() throws {
        let entries = [
            RecoveryKit.Entry(version: 1, secretKey: secretKey1, isRetired: true),
            RecoveryKit.Entry(version: 7, secretKey: secretKey2),
        ]

        XCTAssertEqual(try RecoveryKit.import(RecoveryKit.export(entries: entries)), entries)
    }

    /// Crockford's point is that these characters are unambiguous *if* you map them: someone
    /// copying off paper writes O for 0 and l for 1 whatever the alphabet says.
    func testCommonMisreadingsAreAbsorbed() throws {
        let kit = RecoveryKit.export(entries: [RecoveryKit.Entry(version: 1, secretKey: secretKey1)])
        let retyped = kit
            .lowercased()
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "l")
            .replacingOccurrences(of: "-", with: " ")

        XCTAssertEqual(try RecoveryKit.import(retyped),
                       [RecoveryKit.Entry(version: 1, secretKey: secretKey1)])
    }

    // MARK: - Rejections

    /// Copying by hand truncates. A short read must say so rather than yield a subtly wrong key.
    func testATruncatedKitIsRejected() {
        let kit = RecoveryKit.export(entries: [RecoveryKit.Entry(version: 1, secretKey: secretKey1)])

        XCTAssertThrowsError(try RecoveryKit.import(String(kit.dropLast(12)))) { error in
            XCTAssertEqual(error as? RecoveryKitError, .incomplete)
        }
    }

    func testTextThatIsNotAKitIsRejected() {
        // Every character is in the alphabet, so this gets as far as the frame — which is what the
        // magic byte is for.
        XCTAssertThrowsError(try RecoveryKit.import("2345-6789-2345-6789")) { error in
            XCTAssertEqual(error as? RecoveryKitError, .notARecoveryKit)
        }
    }

    func testACharacterOutsideTheAlphabetIsNamed() {
        XCTAssertThrowsError(try RecoveryKit.import("9R0G-2001-!!!!")) { error in
            XCTAssertEqual(error as? RecoveryKitError, .unexpectedCharacter("!"))
        }
    }

    func testAnEmptyKitIsRejected() {
        XCTAssertThrowsError(try RecoveryKit.import("   \n  ")) { error in
            XCTAssertEqual(error as? RecoveryKitError, .empty)
        }
    }

    /// A keyring without exactly one active key cannot say what new documents seal to.
    func testAKitWithTwoActiveKeysIsRejected() {
        let kit = RecoveryKit.export(entries: [
            RecoveryKit.Entry(version: 1, secretKey: secretKey1),
            RecoveryKit.Entry(version: 2, secretKey: secretKey2),
        ])

        XCTAssertThrowsError(try RecoveryKit.import(kit)) { error in
            XCTAssertEqual(error as? RecoveryKitError, .noSingleActiveKey)
        }
    }

    func testAKitWithDuplicateVersionsIsRejected() {
        let kit = RecoveryKit.export(entries: [
            RecoveryKit.Entry(version: 1, secretKey: secretKey1, isRetired: true),
            RecoveryKit.Entry(version: 1, secretKey: secretKey2),
        ])

        XCTAssertThrowsError(try RecoveryKit.import(kit)) { error in
            XCTAssertEqual(error as? RecoveryKitError, .damaged)
        }
    }

    /// The trailing partial group is padded with zero bits rather than dropped — those bits are key
    /// material, and losing them loses part of the secret key.
    func testTrailingBitsAreKept() {
        let allZero = RecoveryKit.export(entries: [
            RecoveryKit.Entry(version: 1, secretKey: Data(repeating: 0, count: 32)),
        ])
        let lastBitSet = RecoveryKit.export(entries: [
            RecoveryKit.Entry(version: 1,
                              secretKey: Data(repeating: 0, count: 31) + Data([0x01])),
        ])

        XCTAssertNotEqual(allZero, lastBitSet)
    }
}
