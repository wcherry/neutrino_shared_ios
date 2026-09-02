import Foundation
import Security

// MARK: - NeutrinoAppConfig

/// Everything that differs between Drive, Docs, Sheets, Notes and Photos.
///
/// The five apps ran the same auth flow, the same Keychain wrapper and the same key lifecycle,
/// and each carried its own copy because a handful of constants were baked into the middle of
/// them — `"nd."` vs `"ndoc."`, `"neutrino-ios"` vs `"neutrino-docs-ios"`, a `Logger` subsystem
/// string. Those constants live here instead, so the code around them can be shared verbatim.
///
/// Namespacing is the reason the prefix is not simply dropped: a device with all five apps
/// installed keeps five separate sessions, and `nd.access_token` sitting on top of
/// `ndoc.access_token` would sign one app out every time another signed in.
public struct NeutrinoAppConfig: Sendable {

    // MARK: - Identity

    /// Short lowercase identifier, e.g. `"drive"`. Used in log subsystems and diagnostics.
    public let slug: String

    /// User-facing name, e.g. `"Neutrino Drive"`. Shown on the sign-in screen and appended to
    /// the registered device name so the account's device list can tell the apps apart.
    public let displayName: String

    // MARK: - Storage namespace

    /// Prefix on every Keychain account and `UserDefaults` key this package writes, without the
    /// trailing dot — `"nd"`, `"ndoc"`, `"nsheet"`, `"nn"`, `"nphoto"`.
    public let keychainPrefix: String

    // MARK: - OAuth

    /// The `client_id` this app is registered under on the Neutrino auth server.
    public let oauthClientID: String

    /// Where the app points when the user has not chosen a server.
    public let defaultHost: String

    /// The OAuth redirect target. Shared across the apps — the flow never leaves the process, so
    /// there is nothing for the URI to disambiguate.
    public let oauthRedirectURI: String

    // MARK: - App Group

    /// App Group id, for an app that ships an extension needing the same tokens and keys — only
    /// Drive, today, for its share extension. `nil` leaves everything in the app's own container.
    public let appGroupIdentifier: String?

    /// Keychain access group paired with `appGroupIdentifier`. `nil` uses the default group.
    ///
    /// Both are declared rather than derived: the Keychain group is a separate entitlement with
    /// its own value, and guessing one from the other is how an item ends up written somewhere
    /// the extension cannot read it.
    public let keychainAccessGroup: String?

    // MARK: - Keychain protection

    /// `kSecAttrAccessible` for every item this package writes.
    ///
    /// Always a `…ThisDeviceOnly` variant — that half is not negotiable, and is what keeps the
    /// refresh token and the identity secret key out of iCloud Keychain and encrypted backups.
    /// What differs is *when* an item is readable:
    ///
    /// - `AfterFirstUnlock…` (the default) lets a background task read a token on a locked device.
    ///   Drive uploads from a `BGProcessingTask` and Photos syncs the camera roll, and under
    ///   `WhenUnlocked` every such wake-up would fail to read the key and look like a sync that
    ///   silently stopped.
    /// - `WhenUnlocked…` is stricter — the items are unreadable while the device is locked, so a
    ///   phone seized powered-on is a better position. Notes shipped with this and has no
    ///   background transfer path, so it keeps it.
    ///
    /// Per-app rather than a single constant because adopting this package must not quietly
    /// downgrade an app's protection, and `AfterFirstUnlock` is the weaker of the two.
    public let keychainAccessibility: CFString

    // MARK: - Capabilities

    /// Whether the sign-in screen offers account creation. Only Docs shipped a `RegisterView`;
    /// the endpoint is the same for every app, so this is a rollout switch rather than a
    /// statement about the server.
    public let supportsRegistration: Bool

    /// Whether sign-in should handle a TOTP challenge. Drive's `AuthService` grew this; the flow
    /// is harmless when the account has no second factor, so the flag exists to keep the code
    /// field off screens whose apps have not been through 2FA QA yet.
    public let supportsTwoFactor: Bool

    // MARK: - Init

    public init(slug: String,
                displayName: String,
                keychainPrefix: String,
                oauthClientID: String,
                defaultHost: String,
                oauthRedirectURI: String = "neutrino://oauth/callback",
                appGroupIdentifier: String? = nil,
                keychainAccessGroup: String? = nil,
                keychainAccessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                supportsRegistration: Bool = true,
                supportsTwoFactor: Bool = true) {
        self.slug = slug
        self.displayName = displayName
        self.keychainPrefix = keychainPrefix
        self.oauthClientID = oauthClientID
        self.defaultHost = defaultHost
        self.oauthRedirectURI = oauthRedirectURI
        self.appGroupIdentifier = appGroupIdentifier
        self.keychainAccessGroup = keychainAccessGroup
        self.keychainAccessibility = keychainAccessibility
        self.supportsRegistration = supportsRegistration
        self.supportsTwoFactor = supportsTwoFactor
    }

    // MARK: - Derived keys

    /// `"<prefix>.<name>"` — the shape every existing key already had, so a migrated app reads
    /// exactly the items its previous build wrote.
    public func key(_ name: String) -> String {
        "\(keychainPrefix).\(name)"
    }

    /// Canonical key names. Spelled once here rather than at each call site, because a typo in a
    /// Keychain account string fails as "signed out" rather than as a compile error.
    public enum Key {
        public static let accessToken  = "access_token"
        public static let refreshToken = "refresh_token"
        public static let tokenExpiry  = "token_expiry"
        public static let serverHost   = "server_host"
        public static let deviceName   = "device_name"

        public static let publicKey    = "encryption.public_key"
        public static let privateKey   = "encryption.private_key"
        public static let keyVersion   = "encryption.key_version"
        public static let archivedKeys = "encryption.archived_keys"
    }

    public var accessTokenKey:  String { key(Key.accessToken) }
    public var refreshTokenKey: String { key(Key.refreshToken) }
    public var tokenExpiryKey:  String { key(Key.tokenExpiry) }
    public var serverHostKey:   String { key(Key.serverHost) }
    public var deviceNameKey:   String { key(Key.deviceName) }
    public var publicKeyKey:    String { key(Key.publicKey) }
    public var privateKeyKey:   String { key(Key.privateKey) }
    public var keyVersionKey:   String { key(Key.keyVersion) }
    public var archivedKeysKey: String { key(Key.archivedKeys) }

    /// Log subsystem, falling back to the slug when the bundle has no identifier (unit tests).
    public var logSubsystem: String {
        Bundle.main.bundleIdentifier ?? "app.getneutrino.\(slug)"
    }
}

// MARK: - NeutrinoApp

/// The running app's configuration.
///
/// Set once from the `App` initializer, before any service touches the Keychain. It is a global
/// because the alternative is threading a config through `KeychainService.load` and every static
/// helper beneath it — and those statics are what let the share extension read a token without
/// building the app's object graph.
public enum NeutrinoApp {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: NeutrinoAppConfig?

    /// Installs the configuration. Call first thing in the app's `init()`.
    ///
    /// Calling twice is allowed and replaces the config — the tests rely on it. It is not
    /// something an app should do at runtime: services cache nothing from here, but the Keychain
    /// items written under the old prefix do not move.
    public static func configure(_ config: NeutrinoAppConfig) {
        lock.lock()
        defer { lock.unlock() }
        _current = config
    }

    /// The active configuration.
    ///
    /// Traps when unset rather than substituting a default: a default would silently write the
    /// wrong app's Keychain prefix, which surfaces much later as an account that will not stay
    /// signed in. Failing at launch, on the line that forgot to configure, is the cheaper error.
    public static var current: NeutrinoAppConfig {
        lock.lock()
        defer { lock.unlock() }
        guard let config = _current else {
            fatalError(
                "NeutrinoApp.configure(_:) must be called before any Neutrino service is used. "
                + "Add it to your App's init()."
            )
        }
        return config
    }

    /// True once configured. For tests and diagnostics.
    public static var isConfigured: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _current != nil
    }
}
