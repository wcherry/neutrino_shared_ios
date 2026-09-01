import Foundation

// MARK: - NeutrinoStorage

/// `UserDefaults` access for the settings the package owns, chiefly the server host.
///
/// This is Drive's `SharedStorage` with the Drive constants removed. Its reason for existing is
/// unchanged: an app that ships an extension needs the host and the token reachable from a binary
/// that does not build the app's object graph, so these accessors are statics over
/// `NeutrinoApp.current` rather than methods on a service.
///
/// The dual-suite reads are not redundancy for its own sake. An install that predates the App
/// Group wrote its host to `.standard`; the extension can only see the group suite. Reading both
/// and writing both is what stops a user's configured server disappearing on the build that adds
/// the capability.
public enum NeutrinoStorage {

    // MARK: - Defaults suite

    /// `UserDefaults` visible to the app and its extension, or `.standard` when the app declares
    /// no App Group (four of the five apps) or the entitlement is missing (unit tests).
    public static var defaults: UserDefaults {
        guard let appGroup = NeutrinoApp.current.appGroupIdentifier,
              let suite = UserDefaults(suiteName: appGroup)
        else { return .standard }
        return suite
    }

    // MARK: - Server host

    /// The server this app talks to.
    ///
    /// Group suite first so an extension sees whatever host the login screen configured, then
    /// `.standard` for installs predating the group, then the compiled-in default.
    public static var serverHost: String {
        let key = NeutrinoApp.current.serverHostKey
        if let shared = defaults.string(forKey: key), !shared.isEmpty { return shared }
        if let local = UserDefaults.standard.string(forKey: key), !local.isEmpty { return local }
        return NeutrinoApp.current.defaultHost
    }

    /// Writes the host to both suites, so a host set before the App Group shipped and one set
    /// after it agree.
    ///
    /// Trimmed on the way in: a trailing space pasted into the field turns every request URL into
    /// one that will not resolve, and the failure reads as "the server is down".
    public static func setServerHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = NeutrinoApp.current.serverHostKey
        defaults.set(trimmed, forKey: key)
        UserDefaults.standard.set(trimmed, forKey: key)
    }

    // MARK: - Session

    public static func accessToken() -> String? {
        KeychainService.load(forKey: NeutrinoApp.current.accessTokenKey)
    }

    /// True when all three key-material entries are present.
    ///
    /// Lives here rather than on `KeyImportService` so an extension can ask the question without
    /// linking `NeutrinoCrypto` and, through it, libsodium. `KeyImportService.hasStoredKeys()`
    /// delegates here, so there is one implementation behind the two entry points.
    public static func hasStoredKeys() -> Bool {
        let config = NeutrinoApp.current
        return KeychainService.load(forKey: config.publicKeyKey)  != nil
            && KeychainService.load(forKey: config.privateKeyKey) != nil
            && KeychainService.load(forKey: config.keyVersionKey) != nil
    }
}
