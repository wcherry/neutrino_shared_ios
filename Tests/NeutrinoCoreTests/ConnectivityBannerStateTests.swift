import XCTest
@testable import NeutrinoCore

final class ConnectivityBannerStateTests: XCTestCase {

    private func resolve(isOnline: Bool = true, pending: Int = 0, activity: SyncActivity = .idle,
                         keeps: Bool = true, reconnected: Bool = false) -> ConnectivityBannerState? {
        ConnectivityBannerState.resolve(isOnline: isOnline, pendingChanges: pending, activity: activity,
                                        keepsChangesOffline: keeps, justReconnected: reconnected)
    }

    func test_onlineAndIdle_saysNothing() {
        XCTAssertNil(resolve())
    }

    func test_offline_promisesToSyncOnlyWhenTheAppQueues() {
        XCTAssertEqual(resolve(isOnline: false)?.message, "You're offline. Changes will sync when you reconnect.")
        XCTAssertEqual(resolve(isOnline: false, keeps: false)?.message,
                       "You're offline. Showing what's saved on this device.")
    }

    func test_offline_countsWhatIsQueued() {
        XCTAssertEqual(resolve(isOnline: false, pending: 1)?.message, "You're offline. 1 change will sync when you reconnect.")
        XCTAssertEqual(resolve(isOnline: false, pending: 3)?.message, "You're offline. 3 changes will sync when you reconnect.")
    }

    func test_offline_winsOverEverythingAndOffersNoAction() {
        let state = resolve(isOnline: false, pending: 2, activity: .failed("boom"), reconnected: true)
        XCTAssertEqual(state?.kind, .offline)
        XCTAssertNil(state?.actionTitle)
    }

    func test_syncing_countsRemainingThenFallsBackToPending() {
        XCTAssertEqual(resolve(activity: .syncing(remaining: 2))?.message, "Syncing 2 changes…")
        XCTAssertEqual(resolve(pending: 1, activity: .syncing(remaining: 0))?.message, "Syncing 1 change…")
        XCTAssertEqual(resolve(activity: .syncing(remaining: 0))?.message, "Syncing…")
        XCTAssertNil(resolve(activity: .syncing(remaining: 2))?.actionTitle)
    }

    func test_failed_showsTheReasonAndOffersRetry() {
        let state = resolve(pending: 1, activity: .failed("Server error (500)."))
        XCTAssertEqual(state?.kind, .failed)
        XCTAssertEqual(state?.message, "Couldn't sync: Server error (500).")
        XCTAssertEqual(state?.actionTitle, "Retry")
        XCTAssertEqual(resolve(activity: .failed("  "))?.message, "Couldn't sync.")
    }

    func test_waiting_offersSyncNow() {
        let state = resolve(pending: 4)
        XCTAssertEqual(state?.kind, .waiting)
        XCTAssertEqual(state?.message, "4 changes waiting to sync.")
        XCTAssertEqual(state?.actionTitle, "Sync Now")
    }

    func test_reconnected_onlyWhenThereIsNothingElseToSay() {
        XCTAssertEqual(resolve(reconnected: true)?.kind, .reconnected)
        XCTAssertEqual(resolve(pending: 1, reconnected: true)?.kind, .waiting)
        XCTAssertEqual(resolve(activity: .syncing(remaining: 1), reconnected: true)?.kind, .syncing)
    }
}
