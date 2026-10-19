import Foundation

// MARK: - SyncActivity

/// What an app's sync queue is doing, in the terms the connectivity banner needs.
///
/// Each app's engine has its own richer state — Docs separates edits from moves, Calendar has
/// conflicts — and maps it down to this so every app's banner reads the same.
public enum SyncActivity: Equatable, Sendable {
    case idle
    /// Changes are being sent. `remaining` is what is left, or 0 when the engine cannot say.
    case syncing(remaining: Int)
    /// The last pass ended with a failure the user may want to retry.
    case failed(String)
}

// MARK: - ConnectivityBannerState

/// The one line at the top of the app that says whether it is online and what the sync queue is
/// doing — or nil, when there is nothing worth saying.
///
/// Worked out here, away from SwiftUI, so the copy every app shows is decided (and tested) in one
/// place. In priority order:
///
/// 1. **Offline.** Says what still works: an app that queues changes says they will sync; one that
///    cannot ("keepsChangesOffline: false") says it is showing what is saved on the device.
/// 2. **Syncing.** While a pass is running.
/// 3. **Failed.** The last pass's reason, with Retry.
/// 4. **Waiting.** Changes still queued — usually backing off after a failure — with Sync Now.
/// 5. **Back online.** Briefly, after a reconnect, when there is nothing else to say.
public struct ConnectivityBannerState: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        case offline, syncing, failed, waiting, reconnected
    }

    public let kind: Kind
    public let message: String

    /// The button's title, when the banner offers one. Its action is always "sync now".
    public let actionTitle: String?

    /// SF Symbol for the leading icon. A plain string, so this file stays Foundation-only.
    public var symbol: String {
        switch kind {
        case .offline:     return "wifi.slash"
        case .syncing:     return "arrow.triangle.2.circlepath"
        case .failed:      return "exclamationmark.triangle.fill"
        case .waiting:     return "clock.arrow.circlepath"
        case .reconnected: return "wifi"
        }
    }

    public init(kind: Kind, message: String, actionTitle: String? = nil) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
    }

    /// - Parameters:
    ///   - pendingChanges: changes queued on the device and not yet on the server.
    ///   - keepsChangesOffline: whether this app (or screen) queues edits made offline. Drive,
    ///     Sheets and Slides do not, and must not promise to.
    ///   - justReconnected: the view's "came back a moment ago" flag.
    public static func resolve(isOnline: Bool,
                               pendingChanges: Int = 0,
                               activity: SyncActivity = .idle,
                               keepsChangesOffline: Bool = true,
                               justReconnected: Bool = false) -> ConnectivityBannerState? {
        let pending = max(0, pendingChanges)

        guard isOnline else {
            if !keepsChangesOffline {
                return .init(kind: .offline, message: "You're offline. Showing what's saved on this device.")
            }
            if pending > 0 {
                return .init(kind: .offline,
                             message: "You're offline. \(changes(pending)) will sync when you reconnect.")
            }
            return .init(kind: .offline, message: "You're offline. Changes will sync when you reconnect.")
        }

        switch activity {
        case .syncing(let remaining):
            let count = remaining > 0 ? remaining : pending
            return .init(kind: .syncing, message: count > 0 ? "Syncing \(changes(count))…" : "Syncing…")
        case .failed(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(kind: .failed,
                         message: trimmed.isEmpty ? "Couldn't sync." : "Couldn't sync: \(trimmed)",
                         actionTitle: "Retry")
        case .idle:
            break
        }

        if pending > 0 {
            return .init(kind: .waiting, message: "\(changes(pending)) waiting to sync.", actionTitle: "Sync Now")
        }
        if justReconnected {
            return .init(kind: .reconnected, message: "Back online.")
        }
        return nil
    }

    private static func changes(_ count: Int) -> String {
        count == 1 ? "1 change" : "\(count) changes"
    }
}
