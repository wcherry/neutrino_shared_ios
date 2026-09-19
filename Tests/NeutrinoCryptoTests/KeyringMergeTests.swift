import XCTest
@testable import NeutrinoCrypto

// MARK: - KeyringMergeTests

/// The union rule behind cross-app key sharing.
///
/// Six apps write one Keychain item, so a write is never "replace what is there": Docs restoring a
/// recovery kit that carries versions 1–2 must not discard the version 3 Drive obtained by pairing
/// an hour earlier. Every case below is a way that can go wrong silently — a merged keyring that
/// fails to decode on the *next* launch, after the write has already happened, or one that quietly
/// picks a winner between two different keys and orphans everything sealed to the loser.
final class KeyringMergeTests: XCTestCase {

    // MARK: - Fixtures

    private static let userID = "user-1"

    /// A secret key whose bytes are derived from the version, so two entries for one version are
    /// identical and entries for different versions are not.
    private func secret(forVersion version: Int) -> [UInt8] {
        [UInt8](repeating: UInt8(version), count: KeyringCoder.secretKeyBytes)
    }

    private func entry(_ version: Int,
                       retired: Bool = false,
                       secretOverride: [UInt8]? = nil) -> KeyringEntry {
        KeyringEntry(version: version,
                     publicKey: [UInt8](repeating: 0xAB, count: 32),
                     secretKey: secretOverride ?? secret(forVersion: version),
                     createdAt: "2026-0\(version)-01T00:00:00Z",
                     retiredAt: retired ? "2026-0\(version + 1)-01T00:00:00Z" : nil)
    }

    private func keyring(_ entries: [KeyringEntry]) -> Keyring {
        Keyring(userId: Self.userID, entries: entries)
    }

    // MARK: - Union

    func testMergeKeepsVersionsOnlyOneSideHolds() throws {
        let shared = keyring([entry(1, retired: true), entry(2)])
        let local = keyring([entry(3)])

        let merged = try XCTUnwrap(KeyringStore.merge(shared, with: local))

        XCTAssertEqual(merged.entries.map(\.version), [1, 2, 3])
        XCTAssertEqual(merged.userId, Self.userID)
    }

    /// The property `KeyringCoder` enforces on the way back in. A plain concatenation of two
    /// keyrings names two current versions, and the failure lands on the next launch rather than on
    /// the write that caused it.
    func testMergeNamesExactlyOneActiveVersion() throws {
        let shared = keyring([entry(1), entry(2)])   // two actives between them
        let local = keyring([entry(3)])

        let merged = try XCTUnwrap(KeyringStore.merge(shared, with: local))

        XCTAssertEqual(merged.entries.filter(\.isActive).count, 1)
        XCTAssertEqual(merged.active?.version, 3, "the highest version should be the current one")
    }

    /// Round-trip rather than only inspecting the struct: the decoder is the thing that will
    /// reject a bad merge in production, so let it be the judge here too.
    func testMergedKeyringSurvivesEncodingAndDecoding() throws {
        let merged = try XCTUnwrap(KeyringStore.merge(keyring([entry(1), entry(2)]),
                                                      with: keyring([entry(3)])))

        let decoded = try KeyringCoder.decodeJSON(try KeyringCoder.encodeJSON(merged))

        XCTAssertEqual(decoded.entries.map(\.version), [1, 2, 3])
        XCTAssertEqual(decoded.active?.version, 3)
    }

    func testMergeIsIdempotent() throws {
        let keyringA = keyring([entry(1, retired: true), entry(2)])

        let once = try XCTUnwrap(KeyringStore.merge(keyringA, with: keyringA))
        let twice = try XCTUnwrap(KeyringStore.merge(once, with: keyringA))

        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.entries.map(\.version), [1, 2])
        XCTAssertEqual(once.active?.version, 2)
    }

    func testMergeIsOrderIndependent() throws {
        let shared = keyring([entry(1, retired: true), entry(2)])
        let local = keyring([entry(3)])

        let forward = try XCTUnwrap(KeyringStore.merge(shared, with: local))
        let backward = try XCTUnwrap(KeyringStore.merge(local, with: shared))

        XCTAssertEqual(forward.entries.map(\.version), backward.entries.map(\.version))
        XCTAssertEqual(forward.active?.version, backward.active?.version)
    }

    // MARK: - Retirement

    /// An entry retired on one side must not come back as current because the other side still
    /// thought it was — that would seal new work to a key the account has moved off.
    func testAVersionRetiredOnEitherSideStaysRetired() throws {
        let shared = keyring([entry(1, retired: true), entry(2)])
        let stale = keyring([entry(1)])   // this copy predates the rotation

        let merged = try XCTUnwrap(KeyringStore.merge(shared, with: stale))

        XCTAssertEqual(merged.entry(forVersion: 1)?.isActive, false)
        XCTAssertEqual(merged.active?.version, 2)
    }

    /// A version that was already retired keeps the timestamp it came with. Restamping it with
    /// "now" would date every rotation to whenever the apps last happened to sync.
    func testRetirementTimestampsAreNotRewritten() throws {
        let retiredEntry = entry(1, retired: true)
        let merged = try XCTUnwrap(KeyringStore.merge(keyring([retiredEntry, entry(2)]),
                                                      with: keyring([entry(3)])))

        XCTAssertEqual(merged.entry(forVersion: 1)?.retiredAt, retiredEntry.retiredAt)
    }

    /// The entry that *becomes* retired by the merge had no timestamp, so it gets one.
    func testANewlyRetiredVersionGetsATimestamp() throws {
        let merged = try XCTUnwrap(KeyringStore.merge(keyring([entry(2)]),
                                                      with: keyring([entry(3)])))

        XCTAssertNotNil(merged.entry(forVersion: 2)?.retiredAt)
        XCTAssertNil(merged.entry(forVersion: 3)?.retiredAt)
    }

    // MARK: - Conflict

    /// Same version, two different keys: two identities claiming one number. There is no safe
    /// automatic answer — picking either orphans every file sealed to the other — so the merge
    /// refuses and the caller surfaces it.
    func testMergeRefusesWhenOneVersionHasTwoDifferentKeys() {
        let shared = keyring([entry(1)])
        let other = keyring([entry(1, secretOverride: [UInt8](repeating: 0xFF, count: 32))])

        XCTAssertNil(KeyringStore.merge(shared, with: other))
    }
}
