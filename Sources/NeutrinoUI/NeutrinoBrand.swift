import SwiftUI
import NeutrinoCore

// MARK: - NeutrinoBrand

/// The parts of the sign-in experience that differ per app.
///
/// The five apps shipped two entirely different login screens between them — a hero layout in
/// Drive and Notes, a `Form` layout in Docs, Sheets and Photos — and neither was a variant of the
/// other. This package keeps the hero layout and reduces the difference between apps to the values
/// below, which is what "only the title and logo change" means in practice.
///
/// Everything here has a default. An app that sets `title` and `logoSymbol` and nothing else gets
/// a complete, correct screen.
public struct NeutrinoBrand: Sendable {

    // MARK: - Identity

    /// The large title under the logo, e.g. "Neutrino Drive".
    public let title: String

    /// SF Symbol drawn inside the gradient tile.
    public let logoSymbol: String

    /// Asset-catalog image drawn in place of `logoSymbol` when the app ships real artwork.
    /// The symbol stays as the fallback, so an app can adopt the package before its assets land.
    public let logoImageName: String?

    /// One line under the title. Kept short — it wraps on an SE at anything longer.
    public let tagline: String

    // MARK: - Colour

    /// Two-stop gradient for the logo tile and the sign-in button. The first stop also tints the
    /// progress spinner and the tile's shadow, so it should be the app's primary identity colour.
    public let gradient: [Color]

    // MARK: - Trust rows

    /// The three reassurances above the credential fields.
    ///
    /// Defaulted to the set every app can honestly make. Drive and Notes each had one row of their
    /// own — "Zero-knowledge cloud storage", "Synced with Neutrino Drive" — which is why this is
    /// overridable rather than fixed.
    public let trustRows: [TrustRow]

    public struct TrustRow: Sendable, Identifiable {
        public let icon: String
        public let title: String
        public let color: Color
        public var id: String { title }

        public init(icon: String, title: String, color: Color) {
            self.icon = icon
            self.title = title
            self.color = color
        }
    }

    public static let defaultTrustRows: [TrustRow] = [
        TrustRow(icon: "lock.shield.fill", title: "End-to-end encrypted",     color: Color(.systemGreen)),
        TrustRow(icon: "icloud.fill",      title: "Zero-knowledge storage",   color: Color(.systemBlue)),
        TrustRow(icon: "key.fill",         title: "Only you hold your keys",  color: Color(.systemIndigo)),
    ]

    // MARK: - Init

    public init(title: String,
                logoSymbol: String,
                logoImageName: String? = nil,
                tagline: String = "Private by design. Encrypted on your device.",
                gradient: [Color] = [Color(.systemIndigo), Color(.systemBlue)],
                trustRows: [TrustRow] = NeutrinoBrand.defaultTrustRows) {
        self.title = title
        self.logoSymbol = logoSymbol
        self.logoImageName = logoImageName
        self.tagline = tagline
        self.gradient = gradient
        self.trustRows = trustRows
    }

    // MARK: - Derived

    /// The identity colour — the gradient's first stop, or indigo for a single-stop gradient.
    public var accent: Color { gradient.first ?? Color(.systemIndigo) }

    // MARK: - Registration

    /// The active brand.
    ///
    /// Separate from `NeutrinoApp.configure(_:)` so `NeutrinoCore` stays free of SwiftUI — Drive's
    /// share extension links Core for the Keychain and must not pull a UI framework in behind it.
    nonisolated(unsafe) private static var _current: NeutrinoBrand?
    private static let lock = NSLock()

    public static func use(_ brand: NeutrinoBrand) {
        lock.lock()
        defer { lock.unlock() }
        _current = brand
    }

    /// The registered brand, or one derived from `NeutrinoAppConfig.displayName` when an app has
    /// configured its identity but not its visuals. Unlike `NeutrinoApp.current` this does not
    /// trap: a missing brand costs the user a generic logo, not a broken Keychain namespace.
    public static var current: NeutrinoBrand {
        lock.lock()
        defer { lock.unlock() }
        if let brand = _current { return brand }
        return NeutrinoBrand(title: NeutrinoApp.current.displayName, logoSymbol: "lock.icloud.fill")
    }
}

// MARK: - Presets

public extension NeutrinoBrand {

    static let drive = NeutrinoBrand(
        title: "Neutrino Drive",
        logoSymbol: "externaldrive.fill.badge.wifi",
        tagline: "Secure encrypted file storage",
        gradient: [Color(.systemIndigo), Color(.systemBlue)],
        trustRows: [
            TrustRow(icon: "lock.shield.fill", title: "End-to-end encrypted",        color: Color(.systemGreen)),
            TrustRow(icon: "icloud.fill",      title: "Zero-knowledge cloud storage", color: Color(.systemBlue)),
            TrustRow(icon: "key.fill",         title: "Only you hold your keys",      color: Color(.systemIndigo)),
        ]
    )

    static let docs = NeutrinoBrand(
        title: "Neutrino Docs",
        logoSymbol: "doc.text.fill",
        tagline: "Encrypted documents that open anywhere",
        gradient: [Color(.systemBlue), Color(.systemCyan)],
        trustRows: [
            TrustRow(icon: "lock.shield.fill",            title: "End-to-end encrypted",        color: Color(.systemGreen)),
            TrustRow(icon: "arrow.triangle.2.circlepath", title: "Synced with Neutrino Drive",  color: Color(.systemBlue)),
            TrustRow(icon: "key.fill",                    title: "Only you hold your keys",     color: Color(.systemIndigo)),
        ]
    )

    static let sheets = NeutrinoBrand(
        title: "Neutrino Sheets",
        logoSymbol: "tablecells.fill",
        tagline: "Encrypted spreadsheets, on every device",
        gradient: [Color(.systemGreen), Color(.systemMint)],
        trustRows: [
            TrustRow(icon: "lock.shield.fill",            title: "End-to-end encrypted",       color: Color(.systemGreen)),
            TrustRow(icon: "arrow.triangle.2.circlepath", title: "Synced with Neutrino Drive", color: Color(.systemBlue)),
            TrustRow(icon: "key.fill",                    title: "Only you hold your keys",    color: Color(.systemIndigo)),
        ]
    )

    static let slides = NeutrinoBrand(
        title: "Neutrino Slides",
        logoSymbol: "rectangle.on.rectangle.angled",
        tagline: "Encrypted presentations you can show anywhere",
        gradient: [Color(.systemOrange), Color(.systemYellow)],
        trustRows: [
            TrustRow(icon: "lock.shield.fill",            title: "End-to-end encrypted",       color: Color(.systemGreen)),
            TrustRow(icon: "arrow.triangle.2.circlepath", title: "Synced with Neutrino Drive", color: Color(.systemBlue)),
            TrustRow(icon: "key.fill",                    title: "Only you hold your keys",    color: Color(.systemIndigo)),
        ]
    )

    static let notes = NeutrinoBrand(
        title: "Neutrino Notes",
        logoSymbol: "note.text",
        tagline: "Secure Markdown notes for the Neutrino ecosystem",
        gradient: [Color(.systemTeal), Color(.systemGreen)],
        trustRows: [
            TrustRow(icon: "lock.shield.fill",            title: "End-to-end encrypted",       color: Color(.systemGreen)),
            TrustRow(icon: "arrow.triangle.2.circlepath", title: "Synced with Neutrino Drive", color: Color(.systemTeal)),
            TrustRow(icon: "key.fill",                    title: "Only you hold your keys",    color: Color(.systemIndigo)),
        ]
    )

    static let photos = NeutrinoBrand(
        title: "Neutrino Photos",
        logoSymbol: "photo.on.rectangle.angled",
        tagline: "Your photo library, encrypted end to end",
        gradient: [Color(.systemPink), Color(.systemOrange)],
        trustRows: [
            TrustRow(icon: "lock.shield.fill", title: "End-to-end encrypted",        color: Color(.systemGreen)),
            TrustRow(icon: "icloud.fill",      title: "Zero-knowledge cloud storage", color: Color(.systemBlue)),
            TrustRow(icon: "key.fill",         title: "Only you hold your keys",      color: Color(.systemIndigo)),
        ]
    )
}
