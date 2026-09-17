import Foundation

// MARK: - RecoveryKit ⇄ Keyring
//
// `RecoveryKit` deals in bare `Entry` values — version, secret key, retired — because the printed
// frame carries nothing else, and because the split-store apps have no `Keyring` to hand it. An app
// on the keyring model does, so these two are the bridge: same frame, same validation, expressed in
// the type its callers already hold.
//
// Timestamps are the one thing that cannot survive the round trip. The frame has no room for them
// — see the note in `RecoveryKit` on why that is deliberate — so a restored entry is stamped with
// the moment of the restore. They are display metadata; nothing reads them to open a file.

public extension RecoveryKit {

    /// Render a whole keyring as the printable kit.
    ///
    /// Every version goes in, not just the active key: a file sealed to version 1 needs version 1,
    /// and a kit that restored only the newest key would come back to a library it cannot open.
    static func export(_ keyring: Keyring) -> String {
        export(entries: keyring.entries.map {
            Entry(version: $0.version,
                  secretKey: Data($0.secretKey),
                  isRetired: !$0.isActive)
        })
    }

    /// Rebuild a keyring from a printed kit.
    ///
    /// `userId` comes from the signed-in session rather than the kit: the kit holds key material
    /// only, and binding it to an account is the caller's business.
    ///
    /// The public halves are derived here rather than carried, so a kit that was mistyped into
    /// something that still decodes cannot produce a pair whose halves disagree.
    static func importKit(_ text: String, userId: String) throws -> Keyring {
        let entries = try `import`(text)
        let now = ISO8601DateFormatter().string(from: Date())

        let keyringEntries: [KeyringEntry] = try entries.map { entry in
            guard entry.secretKey.count == KeyringCoder.secretKeyBytes,
                  let publicKey = KeyringCoder.publicKey(fromSecret: [UInt8](entry.secretKey))
            else {
                throw RecoveryKitError.damaged
            }
            return KeyringEntry(version: entry.version,
                                publicKey: publicKey,
                                secretKey: [UInt8](entry.secretKey),
                                createdAt: now,
                                retiredAt: entry.isRetired ? now : nil)
        }

        // `import` already rejects duplicates and anything without exactly one active entry, and
        // returns them sorted, so there is nothing left to check here.
        return Keyring(userId: userId, entries: keyringEntries)
    }

    /// True if `text` could plausibly be a kit, for deciding which field to accept.
    ///
    /// Length rather than a full decode: this runs while the user is still typing, and a kit that
    /// is merely half-entered should not be reported as damaged.
    static func looksLikeKit(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard normalized.count >= 60 else { return false }
        return normalized.allSatisfy { alphabet.contains($0) }
    }
}
