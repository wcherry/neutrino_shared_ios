import Foundation
import UIKit
import NeutrinoCore

// MARK: - DeviceIdentity

/// This installation's identity, as the Neutrino auth service records it.
///
/// There is no separate registration endpoint on the server: a device registers by naming itself
/// in the `X-Device-Name` header when it logs in, which populates `device_name` on the session row
/// that `GET /api/v1/auth/sessions` lists and `DELETE /api/v1/auth/sessions/{id}` revokes.
/// Registration is therefore a property of login, not a call of its own — and this is what login
/// sends.
public enum DeviceIdentity {

    // MARK: - Device name

    /// The name this device registers under, e.g. "Will's iPhone — Neutrino Drive".
    ///
    /// A user-set override wins; otherwise the device's own name is used. The app's display name
    /// is appended so the sessions list can tell the five apps apart, which all report an
    /// identical `UIDevice.name` on the same hardware.
    public static var deviceName: String {
        if let custom = UserDefaults.standard.string(forKey: NeutrinoApp.current.deviceNameKey),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return "\(UIDevice.current.name) — \(NeutrinoApp.current.displayName)"
    }

    /// Overrides the registered device name. Passing nil (or blank) restores the default.
    public static func setDeviceName(_ name: String?) {
        let key = NeutrinoApp.current.deviceNameKey
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Header name sent on login. Kept here so `AuthService` and its tests agree on it.
    public static let deviceNameHeader = "X-Device-Name"
}

// MARK: - DeviceSession

/// One registered device (an active refresh-token session) from `GET /api/v1/auth/sessions`.
public struct DeviceSession: Identifiable, Hashable, Decodable, Sendable {

    // MARK: - Properties

    public let id: String
    /// What the device called itself via `X-Device-Name` at login. Nil for clients that sent none.
    public let deviceName: String?
    public let userAgent: String?
    public let ipAddress: String?
    public let createdAt: Date
    public let lastUsedAt: Date?

    // MARK: - Init

    public init(id: String, deviceName: String?, userAgent: String? = nil, ipAddress: String? = nil,
                createdAt: Date, lastUsedAt: Date? = nil) {
        self.id = id
        self.deviceName = deviceName
        self.userAgent = userAgent
        self.ipAddress = ipAddress
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    // MARK: - Display

    /// Name to show in the devices list, falling back through the user agent to a generic label
    /// rather than leaving the row blank.
    public var displayName: String {
        if let deviceName, !deviceName.trimmingCharacters(in: .whitespaces).isEmpty {
            return deviceName
        }
        if let userAgent, !userAgent.trimmingCharacters(in: .whitespaces).isEmpty {
            return userAgent
        }
        return "Unknown device"
    }

    /// True when this row is the device the app is running on, matched by the name it registered
    /// under. The server does not mark the caller's own session, and the session id is not
    /// something the token exchange hands back, so the registered name is the only join available.
    public var isCurrentDevice: Bool {
        deviceName == DeviceIdentity.deviceName
    }

    /// "Last used 2 Aug 2026 at 09:20", or the creation date when it has never been used since.
    public var lastUsedText: String {
        let date = lastUsedAt ?? createdAt
        let prefix = lastUsedAt == nil ? "Registered" : "Last used"
        return "\(prefix) \(Self.formatter.string(from: date))"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Decoding

    /// Session timestamps are `NaiveDateTime` — Drive's zone-less shape.
    public static var decoder: JSONDecoder { DriveDate.makeDecoder() }
}
