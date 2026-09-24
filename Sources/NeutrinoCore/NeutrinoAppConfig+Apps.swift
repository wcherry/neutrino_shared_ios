import Foundation
import Security

// MARK: - The apps

/// The shipped configuration for each Neutrino iOS app.
///
/// These live in the package rather than in each app so adoption is one line — `NeutrinoApp
/// .configure(.drive)` — and, more importantly, so the namespacing contract is checkable. Six
/// apps writing six prefixes cannot be verified when the prefixes live in six repositories; here
/// a test asserts that no two of them collide.
///
/// **Every value below is load-bearing on an installed device.** The prefixes are what the shipped
/// builds already wrote to the Keychain, so changing one does not renamespace an app — it signs its
/// users out and orphans their imported encryption key.
public extension NeutrinoAppConfig {

    /// The Keychain access group every app declares, holding the identity keyring.
    ///
    /// Spelled once so the six configs cannot drift: two apps naming *almost* the same group is a
    /// device where the key is shared with four apps out of six, which looks like a bug in the
    /// fifth. The entitlement writes it as `$(AppIdentifierPrefix)com.neutrino.shared`; the team
    /// prefix is added at runtime — see `KeychainService.bundleSeedPrefix()`.
    ///
    /// Note what opting in costs Notes: the shared item carries
    /// `NeutrinoAppConfig.sharedKeyringAccessibility` (`AfterFirstUnlock`), not Notes' own stricter
    /// `WhenUnlocked`, because one item has one accessibility and Drive's share extension reads it
    /// on a locked device. Notes' tokens are unaffected. Setting this to nil for Notes is the
    /// supported way to decline that trade; it then keeps a private keyring and imports its own.
    static let sharedIdentityGroup = "com.neutrino.shared"

    /// Neutrino Drive. The only app with an extension, hence the only App Group.
    static let drive = NeutrinoAppConfig(
        slug: "drive",
        displayName: "Neutrino Drive",
        contentNoun: "files",
        keychainPrefix: "nd",
        oauthClientID: "neutrino-ios",
        defaultHost: "http://localhost:8080",
        appGroupIdentifier: "group.com.neutrino.drive",
        keychainAccessGroup: "com.neutrino.drive.shared",
        sharedKeychainAccessGroup: Self.sharedIdentityGroup,
        // Drive had no register screen; its login is the one that grew 2FA.
        supportsRegistration: true,
        supportsTwoFactor: true
    )

    static let docs = NeutrinoAppConfig(
        slug: "docs",
        displayName: "Neutrino Docs",
        contentNoun: "documents",
        keychainPrefix: "ndoc",
        oauthClientID: "neutrino-docs-ios",
        defaultHost: "https://www.getneutrino.app",
        sharedKeychainAccessGroup: Self.sharedIdentityGroup,
        supportsRegistration: true,
        // Docs' sign-in has never been through a 2FA account. The flow is harmless when the
        // account has no second factor, so this flips on once QA has an enrolled test account.
        supportsTwoFactor: false
    )

    static let sheets = NeutrinoAppConfig(
        slug: "sheets",
        displayName: "Neutrino Sheets",
        contentNoun: "spreadsheets",
        keychainPrefix: "nsheet",
        oauthClientID: "neutrino-sheets-ios",
        defaultHost: "https://www.getneutrino.app",
        sharedKeychainAccessGroup: Self.sharedIdentityGroup,
        supportsRegistration: true,
        supportsTwoFactor: false
    )

    static let notes = NeutrinoAppConfig(
        slug: "notes",
        displayName: "Neutrino Notes",
        contentNoun: "notes",
        keychainPrefix: "nn",
        oauthClientID: "neutrino-notes-ios",
        defaultHost: "https://www.getneutrino.app",
        sharedKeychainAccessGroup: Self.sharedIdentityGroup,
        // Notes shipped with the stricter `WhenUnlocked` and has no background transfer path that
        // needs to read a token on a locked device. Adopting this package must not downgrade it.
        keychainAccessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        supportsRegistration: true,
        supportsTwoFactor: false
    )

    static let photos = NeutrinoAppConfig(
        slug: "photos",
        displayName: "Neutrino Photos",
        contentNoun: "photos",
        keychainPrefix: "nphoto",
        oauthClientID: "neutrino-photos-ios",
        defaultHost: "https://www.getneutrino.app",
        sharedKeychainAccessGroup: Self.sharedIdentityGroup,
        supportsRegistration: true,
        supportsTwoFactor: false,
        // Photos is the only app that shows the signed-in account, and the only one whose sign-in
        // already made this call.
        loadsProfileOnLogin: true
    )

    static let slides = NeutrinoAppConfig(
        slug: "slides",
        displayName: "Neutrino Slides",
        contentNoun: "presentations",
        keychainPrefix: "nslide",
        oauthClientID: "neutrino-slides-ios",
        defaultHost: "https://www.getneutrino.app",
        sharedKeychainAccessGroup: Self.sharedIdentityGroup,
        supportsRegistration: true,
        supportsTwoFactor: false
    )

    /// The OAuth client is seeded by `neutrino/migrations/00135_oauth__*`, not by the original
    /// `00095_oauth__*` that registered the other six.
    static let calendar = NeutrinoAppConfig(
        slug: "calendar",
        displayName: "Neutrino Calendar",
        contentNoun: "events",
        keychainPrefix: "ncal",
        oauthClientID: "neutrino-calendar-ios",
        defaultHost: "https://www.getneutrino.app",
        sharedKeychainAccessGroup: Self.sharedIdentityGroup,
        supportsRegistration: true,
        supportsTwoFactor: false
    )

    /// Every shipped app. Exists so the collision test cannot silently miss one that was added
    /// without being registered.
    static let allApps: [NeutrinoAppConfig] = [
        .drive, .docs, .sheets, .notes, .photos, .slides, .calendar,
    ]
}
