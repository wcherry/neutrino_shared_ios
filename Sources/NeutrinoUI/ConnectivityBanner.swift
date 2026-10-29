// iOS-only for now: this target is UIKit/SwiftUI-for-iOS and is compiled out on macOS, where
// only NeutrinoCore, NeutrinoAuth, NeutrinoCrypto and NeutrinoOOXML are built. See Package.swift.
#if os(iOS)

import SwiftUI
import NeutrinoCore

// MARK: - ConnectivityBanner

/// The strip under the status bar that says the app is offline, syncing, stuck, or back.
///
/// Every app mounts one at its root with `.connectivityBanner(...)` and feeds it from its own
/// `NetworkMonitor` and sync engine; the copy is `ConnectivityBannerState`'s, so it reads the same
/// everywhere. It takes no space when there is nothing to say.
///
/// "Back online" is the one state the banner keeps itself: the moment of reconnecting is a
/// transition, not something any monitor publishes, so it is noticed here and shown for a couple
/// of seconds.
public struct ConnectivityBanner: View {

    private let isOnline: Bool
    private let pendingChanges: Int
    private let activity: SyncActivity
    private let keepsChangesOffline: Bool
    private let onRetry: (() -> Void)?

    /// Set the first time the view sees the device offline, so the very first `isOnline == true`
    /// at launch is not mistaken for a reconnect.
    @State private var hasBeenOffline = false
    @State private var justReconnected = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long "Back online" stays up.
    private static let reconnectedDwell: UInt64 = 2_500_000_000

    public init(isOnline: Bool,
                pendingChanges: Int = 0,
                activity: SyncActivity = .idle,
                keepsChangesOffline: Bool = true,
                onRetry: (() -> Void)? = nil) {
        self.isOnline = isOnline
        self.pendingChanges = pendingChanges
        self.activity = activity
        self.keepsChangesOffline = keepsChangesOffline
        self.onRetry = onRetry
    }

    private var state: ConnectivityBannerState? {
        ConnectivityBannerState.resolve(isOnline: isOnline,
                                        pendingChanges: pendingChanges,
                                        activity: activity,
                                        keepsChangesOffline: keepsChangesOffline,
                                        justReconnected: justReconnected)
    }

    public var body: some View {
        // A container that is always there, so the task below sees every change of `isOnline`
        // even while the banner itself is hidden.
        VStack(spacing: 0) {
            if let state {
                row(state)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: state)
        .task(id: isOnline) { await track(isOnline: isOnline) }
    }

    @ViewBuilder
    private func row(_ state: ConnectivityBannerState) -> some View {
        HStack(spacing: 8) {
            if state.kind == .syncing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: state.symbol)
                    .foregroundStyle(tint(state.kind))
            }
            Text(state.message)
                .foregroundStyle(state.kind == .failed ? Color(.label) : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let title = state.actionTitle, let onRetry, isOnline {
                Button(title, action: onRetry)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("connectivityBannerAction")
            }
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(background(state.kind))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectivityBanner")
    }

    private func tint(_ kind: ConnectivityBannerState.Kind) -> Color {
        switch kind {
        case .offline, .waiting: return .secondary
        case .syncing:           return .accentColor
        case .failed:            return .orange
        case .reconnected:       return .green
        }
    }

    @ViewBuilder
    private func background(_ kind: ConnectivityBannerState.Kind) -> some View {
        switch kind {
        case .failed: Color.orange.opacity(0.14).background(.bar)
        default:      Rectangle().fill(.bar)
        }
    }

    // MARK: - Reconnect

    private func track(isOnline: Bool) async {
        guard isOnline else {
            hasBeenOffline = true
            justReconnected = false
            return
        }
        guard hasBeenOffline else { return }
        hasBeenOffline = false
        justReconnected = true
        try? await Task.sleep(nanoseconds: Self.reconnectedDwell)
        // A cancelled sleep means connectivity changed again; that run owns the flag now.
        if !Task.isCancelled { justReconnected = false }
    }
}

// MARK: - View modifier

extension View {

    /// Pins a `ConnectivityBanner` under the top safe area, pushing the content down while it shows.
    public func connectivityBanner(isOnline: Bool,
                                   pendingChanges: Int = 0,
                                   activity: SyncActivity = .idle,
                                   keepsChangesOffline: Bool = true,
                                   onRetry: (() -> Void)? = nil) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            ConnectivityBanner(isOnline: isOnline,
                               pendingChanges: pendingChanges,
                               activity: activity,
                               keepsChangesOffline: keepsChangesOffline,
                               onRetry: onRetry)
        }
    }
}

#endif
