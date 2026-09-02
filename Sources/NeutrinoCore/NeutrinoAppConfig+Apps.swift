import Foundation
import Security

// MARK: - The five apps

/// The shipped configuration for each Neutrino iOS app.
///
/// These live in the package rather than in each app so adoption is one line — `NeutrinoApp
/// .configure(.drive)` — and, more importantly, so the namespacing contract is checkable. Five
/// apps writing five prefixes cannot be verified when the prefixes live in five repositories; here
/// a test asserts that no two of them collide.
///
/// **Every value below is load-bearing on an installed device.** The prefixes are what the shipped
/// builds already wrote to the Keychain, so changing one does not renamespace an app — it signs its
/// users out and orphans their imported encryption key.
public extension NeutrinoAppConfig {

    /// Neutrino Drive. The only app with an extension, hence the only App Group.
    static let drive = NeutrinoAppConfig(
        slug: "drive",
        displayName: "Neutrino Drive",
        keychainPrefix: "nd",
        oauthClientID: "neutrino-ios",
        defaultHost: "http://localhost:8080",
        appGroupIdentifier: "group.com.neutrino.drive",
        keychainAccessGroup: "com.neutrino.drive.shared",
        // Drive had no register screen; its login is the one that grew 2FA.
        supportsRegistration: true,
        supportsTwoFactor: true
    )

    static let docs = NeutrinoAppConfig(
        slug: "docs",
        displayName: "Neutrino Docs",
        keychainPrefix: "ndoc",
        oauthClientID: "neutrino-docs-ios",
        defaultHost: "https://www.getneutrino.app",
        supportsRegistration: true,
        // Docs' sign-in has never been through a 2FA account. The flow is harmless when the
        // account has no second factor, so this flips on once QA has an enrolled test account.
        supportsTwoFactor: false
    )

    static let sheets = NeutrinoAppConfig(
        slug: "sheets",
        displayName: "Neutrino Sheets",
        keychainPrefix: "nsheet",
        oauthClientID: "neutrino-sheets-ios",
        defaultHost: "https://www.getneutrino.app",
        supportsRegistration: true,
        supportsTwoFactor: false
    )

    static let notes = NeutrinoAppConfig(
        slug: "notes",
        displayName: "Neutrino Notes",
        keychainPrefix: "nn",
        oauthClientID: "neutrino-notes-ios",
        defaultHost: "https://www.getneutrino.app",
        // Notes shipped with the stricter `WhenUnlocked` and has no background transfer path that
        // needs to read a token on a locked device. Adopting this package must not downgrade it.
        keychainAccessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        supportsRegistration: true,
        supportsTwoFactor: false
    )

    static let photos = NeutrinoAppConfig(
        slug: "photos",
        displayName: "Neutrino Photos",
        keychainPrefix: "nphoto",
        oauthClientID: "neutrino-photos-ios",
        defaultHost: "https://www.getneutrino.app",
        supportsRegistration: true,
        supportsTwoFactor: false,
        // Photos is the only app that shows the signed-in account, and the only one whose sign-in
        // already made this call.
        loadsProfileOnLogin: true
    )

    /// Every shipped app. Exists so the collision test cannot silently miss one that was added
    /// without being registered.
    static let allApps: [NeutrinoAppConfig] = [.drive, .docs, .sheets, .notes, .photos]
}
