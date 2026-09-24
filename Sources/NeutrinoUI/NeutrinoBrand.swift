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

    /// Two-stop gradient for the sign-in button. The first stop is also the app's `accent`, which
    /// tints the progress spinner and the "Create Account" link, so it should be the app's primary
    /// identity colour — and, because both of those put it against white or under white text, one
    /// that is dark enough to read that way.
    public let gradient: [Color]

    /// Two-stop gradient for the logo tile, when it differs from `gradient`.
    ///
    /// Defaults to `gradient`, which is what five of the six apps want: one identity colour, used
    /// everywhere. It is separable because the tile is the one surface where the colour is pure
    /// decoration — a large mark on a large field, with nothing small or textual on top — so it can
    /// carry a colour that the button and the link cannot. Notes is yellow here and stays teal on
    /// the button, because white 17pt on `systemYellow` is about 1.5:1 and unreadable, while the
    /// same yellow behind a 40pt glyph is fine.
    ///
    /// Set it only when the two genuinely differ; an app that passes one gradient still gets one
    /// gradient everywhere.
    public let logoGradient: [Color]

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
                logoGradient: [Color]? = nil,
                trustRows: [TrustRow] = NeutrinoBrand.defaultTrustRows) {
        self.title = title
        self.logoSymbol = logoSymbol
        self.logoImageName = logoImageName
        self.tagline = tagline
        self.gradient = gradient
        self.logoGradient = logoGradient ?? gradient
        self.trustRows = trustRows
    }

    // MARK: - Derived

    /// The identity colour — the gradient's first stop, or indigo for a single-stop gradient.
    public var accent: Color { gradient.first ?? Color(.systemIndigo) }

    /// The logo tile's own identity colour, for the glow cast behind it. Follows `logoGradient`
    /// rather than `accent` so the glow matches the tile it comes from.
    public var logoAccent: Color { logoGradient.first ?? accent }

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
        // A drive on a connection line — macOS's own mark for a mounted network volume,
        // which is what Neutrino Drive is once the File Provider extension surfaces it in
        // Finder. It replaces `externaldrive.fill.badge.wifi`, a portable bus-powered disk:
        // the wrong kind of drive, and at icon size its wifi arcs collided with the body
        // badly enough to read as some other appliance entirely.
        logoSymbol: "externaldrive.connected.to.line.below.fill",
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
        // Red into a lighter red, the way docs runs blue into cyan. It was orange into yellow,
        // which is now Notes' tile, and two tiles cannot share the same two stops.
        //
        // The second stop is a literal because the palette has no light red to reach for: iOS
        // offers red, pink and orange, and of those pink is fractionally *darker* than red while
        // orange is a different hue that photos already ends on. The value is picked for its fall
        // — about 0.14 in relative luminance against red, where docs' blue into cyan falls 0.15,
        // so this tile lightens by the same amount as the one it is modelled on.
        //
        // Held at blue 110 rather than lower. Lightening a red means desaturating it, since red
        // starts with its red channel already at maximum; holding blue down keeps the saturation
        // but bends the colour towards orange, and this set has two warm tiles already.
        //
        // Static, unlike the system colours either side of it. Dark mode would shift it by about
        // as much as it shifts systemRed, which is nothing you would notice on a gradient, and the
        // app icon it matches is a PNG that cannot shift at all.
        gradient: [Color(.systemRed), Color(red: 1.0, green: 0.510, blue: 0.431)],
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
        // Yellow, the colour a paper note is — on the tile only. It cannot be the app's `gradient`
        // as well: that one backs the sign-in button under a white 17pt label and supplies `accent`
        // for the "Create Account" link on white, and `systemYellow` is about 1.5:1 in both places,
        // which is unreadable rather than merely low. Behind a 40pt glyph on a 96pt tile it is
        // fine.
        //
        // Orange into yellow, not the reverse: every tile in the set runs dark stop into light one
        // — indigo into blue, blue into cyan, pink into orange — so the light falls the same way
        // across a home screen holding several of these. Yellow is the lightest colour in the
        // palette, so the darker end of a yellow identity has to be orange.
        //
        // The app icon in `neutrino_notes_ios_mobile` is these same two stops, vertically.
        logoGradient: [Color(.systemOrange), Color(.systemYellow)],
        trustRows: [
            TrustRow(icon: "lock.shield.fill",            title: "End-to-end encrypted",       color: Color(.systemGreen)),
            TrustRow(icon: "arrow.triangle.2.circlepath", title: "Synced with Neutrino Drive", color: Color(.systemTeal)),
            TrustRow(icon: "key.fill",                    title: "Only you hold your keys",    color: Color(.systemIndigo)),
        ]
    )

    static let calendar = NeutrinoBrand(
        title: "Neutrino Calendar",
        logoSymbol: "calendar",
        tagline: "Your schedule, across every Neutrino device",
        // Purple into pink: no other tile uses purple, and it runs dark stop into light like the
        // rest of the set.
        gradient: [Color(.systemPurple), Color(.systemPink)],
        // No "End-to-end encrypted" row, unlike the other six. Calendar events are stored
        // readable on the server — Google and Outlook sync needs them to be — so the claim would
        // be false here. Attachments are Drive files and are encrypted, so that row is true.
        trustRows: [
            TrustRow(icon: "arrow.triangle.2.circlepath", title: "Synced with your Neutrino account",      color: Color(.systemBlue)),
            TrustRow(icon: "calendar.badge.plus",         title: "Google, Outlook and iCloud in one place", color: Color(.systemPurple)),
            TrustRow(icon: "paperclip",                   title: "Attachments encrypted in Drive",          color: Color(.systemGreen)),
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
