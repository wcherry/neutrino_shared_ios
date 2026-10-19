import XCTest
@testable import NeutrinoCore

final class OfflineFileCacheTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ofc-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func cache(maxEntries: Int = 30, maxBytes: Int = 1_000) -> OfflineFileCache {
        OfflineFileCache(directory: directory, maxEntries: maxEntries, maxBytes: maxBytes)
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

    func test_storeThenCopy_roundTripsEverything() throws {
        let sut = cache()
        try sut.store(fileID: "f1", ciphertext: Data([1, 2, 3]), sealedKey: "sealed", keyVersion: 3,
                      metadata: Data("meta".utf8), now: at(0))

        let copy = try XCTUnwrap(sut.copy(for: "f1"))
        XCTAssertEqual(copy.ciphertext, Data([1, 2, 3]))
        XCTAssertEqual(copy.entry.sealedKey, "sealed")
        XCTAssertEqual(copy.entry.keyVersion, 3)
        XCTAssertEqual(copy.entry.metadata, Data("meta".utf8))
        XCTAssertEqual(copy.entry.storedAt, at(0))
    }

    func test_store_replacesAnEarlierCopy() throws {
        let sut = cache()
        try sut.store(fileID: "f1", ciphertext: Data([1]), sealedKey: "a", keyVersion: 1, metadata: Data(), now: at(0))
        try sut.store(fileID: "f1", ciphertext: Data([2, 2]), sealedKey: "b", keyVersion: 2, metadata: Data(), now: at(1))

        XCTAssertEqual(sut.copy(for: "f1")?.ciphertext, Data([2, 2]))
        XCTAssertEqual(sut.entries.count, 1)
    }

    func test_trim_dropsTheOldestBeyondTheCount() throws {
        let sut = cache(maxEntries: 2)
        for (index, id) in ["a", "b", "c"].enumerated() {
            try sut.store(fileID: id, ciphertext: Data([1]), sealedKey: "", keyVersion: 1, metadata: Data(),
                          now: at(TimeInterval(index)))
        }
        XCTAssertEqual(sut.entries.map(\.fileID), ["c", "b"])
        XCTAssertNil(sut.copy(for: "a"))
    }

    func test_trim_dropsTheOldestBeyondTheBytes() throws {
        let sut = cache(maxBytes: 10)
        try sut.store(fileID: "a", ciphertext: Data(count: 6), sealedKey: "", keyVersion: 1, metadata: Data(), now: at(0))
        try sut.store(fileID: "b", ciphertext: Data(count: 6), sealedKey: "", keyVersion: 1, metadata: Data(), now: at(1))
        XCTAssertEqual(sut.entries.map(\.fileID), ["b"])
    }

    func test_aBodyLargerThanTheBudgetIsNotKept_andDropsTheOldCopy() throws {
        let sut = cache(maxBytes: 4)
        try sut.store(fileID: "a", ciphertext: Data(count: 2), sealedKey: "", keyVersion: 1, metadata: Data(), now: at(0))
        try sut.store(fileID: "a", ciphertext: Data(count: 5), sealedKey: "", keyVersion: 1, metadata: Data(), now: at(1))
        XCTAssertNil(sut.copy(for: "a"), "a stale copy is worse than none")
    }

    func test_anEntryWithoutItsBodyIsNoCopy() throws {
        let sut = cache()
        try sut.store(fileID: "a", ciphertext: Data([1, 2]), sealedKey: "", keyVersion: 1, metadata: Data(), now: at(0))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("a.blob"))
        XCTAssertNil(sut.copy(for: "a"))
    }

    func test_anIdCannotEscapeTheDirectory() throws {
        let sut = cache()
        try sut.store(fileID: "../../evil", ciphertext: Data([1]), sealedKey: "", keyVersion: 1, metadata: Data(), now: at(0))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.allSatisfy { !$0.contains("/") })
        XCTAssertEqual(sut.copy(for: "../../evil")?.ciphertext, Data([1]))
    }

    func test_removeAll_forgetsEverything() throws {
        let sut = cache()
        try sut.store(fileID: "a", ciphertext: Data([1]), sealedKey: "", keyVersion: 1, metadata: Data(), now: at(0))
        sut.removeAll()
        XCTAssertTrue(sut.entries.isEmpty)
        XCTAssertNil(sut.copy(for: "a"))
    }
}
