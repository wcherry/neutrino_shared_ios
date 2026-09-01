import Foundation

// MARK: - Base64URL

/// base64url, the encoding every Neutrino key, nonce and ciphertext travels in.
///
/// Tolerant on the way in and strict on the way out. The server writes unpadded base64url; an
/// exported key file may be standard base64 with padding, and `KeyImportService` deliberately
/// stores whatever string it was handed rather than re-encoding it. A decoder that accepts only
/// one alphabet therefore rejects real keys — which is exactly the bug `keyImportFormat.test.ts`
/// records on the web side, where a bare `atob` threw on any key whose bytes happened to encode
/// with a `-` or a `_`.
///
/// Each app had its own copy of this, usually as a private extension buried in a content service.
public extension Data {

    /// Decodes base64 or base64url, padded or not.
    init?(base64URLEncoded string: String) {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder != 0 {
            standard += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: standard) else { return nil }
        self = data
    }

    /// Encodes as unpadded base64url — the form the server and web app expect.
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
