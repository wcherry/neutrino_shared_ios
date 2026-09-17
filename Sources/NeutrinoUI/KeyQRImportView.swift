import SwiftUI
import VisionKit
import NeutrinoCore
import NeutrinoCrypto

// MARK: - KeyQRImportView

/// Imports the encryption key from the PIN-protected QR code the Neutrino web app shows under
/// Settings → Encryption → "Key code for mobile".
///
/// Four steps: scan, enter the PIN that protects the payload, hand the decrypted JSON to
/// `KeyImportService` — the same validation and Keychain storage the file import path uses — and
/// then pull the account's **retired** keys with `KeyFileService`.
///
/// That last step is not optional dressing. The code carries one keypair, the account's active one,
/// so without the pull a phone joining a rotated account opens everything written since the last
/// rotation and nothing written before it: the documents list, download, and refuse to decrypt.
///
/// This is the **split-store** form: the key lands in the three Keychain items `KeyImportService`
/// writes, with the retired versions in `KeyArchive` beside them. An app on the keyring model wants
/// `KeyringQRImportView`, which is otherwise the same screen. See the note in `Keyring.swift`.
public struct KeyQRImportView: View {

    @Binding private var isPresented: Bool
    /// Called once the Keychain has been written, with the imported key version and a note about
    /// what the key-file pull recovered (nil when there was nothing worth saying), so the
    /// presenting sheet can show its own confirmation and close.
    private let onImported: (String, String?) -> Void

    public init(isPresented: Binding<Bool>,
                onImported: @escaping (String, String?) -> Void = { _, _ in }) {
        self._isPresented = isPresented
        self.onImported = onImported
    }

    @State private var step: ImportStep = .scanning
    @State private var pin = ""
    @State private var isDecrypting = false

    public var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .scanning:
                    scanningView
                case .enterPin(let qrString):
                    pinEntryView(qrString: qrString)
                case .success(let keyVersion, let note):
                    successView(keyVersion: keyVersion, note: note)
                case .error(let message):
                    errorView(message: message)
                }
            }
            .navigationTitle("Scan Key QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }

    // MARK: - Steps

    private var scanningView: some View {
        Group {
            // Unsupported on the Simulator and on devices without a Neural Engine — the file and
            // paste paths remain, so this is a dead end rather than a failure.
            if DataScannerViewController.isSupported {
                ZStack(alignment: .bottom) {
                    QRScannerView { qrString in
                        DispatchQueue.main.async {
                            pin = ""
                            step = .enterPin(qrString: qrString)
                        }
                    }
                    .ignoresSafeArea(edges: .top)

                    Text("Point your camera at the key QR code shown by the Neutrino web app.")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 32)
                }
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("QR scanning isn't supported on this device.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Import the key file or paste the key JSON instead.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.horizontal, 32)
            }
        }
    }

    private func pinEntryView(qrString: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("Enter your PIN")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter the PIN used to protect this key QR code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .padding(.horizontal, 32)

            if isDecrypting {
                ProgressView()
                    .padding(.top, 8)
            } else {
                Button {
                    decryptAndImport(qrString: qrString)
                } label: {
                    Text("Decrypt & Import")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(pin.isEmpty ? Color.accentColor.opacity(0.4) : Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(pin.isEmpty)
                .padding(.horizontal, 32)
            }

            Spacer()
        }
    }

    private func successView(keyVersion: String, note: String?) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("Key imported (version \(keyVersion))")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            // Whether the older documents open is decided by the pull, so its result is stated
            // here rather than left to be discovered one unreadable document at a time.
            if let note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)

            Text("Import Failed")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                pin = ""
                step = .scanning
            } label: {
                Text("Try Again")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Key file

    /// Pull the account's retired keys and describe what came back, or nil when there is nothing
    /// the user needs to know.
    ///
    /// The stale case is worth its own message: it means the *page* that produced this code was
    /// built before a rotation it has not caught up with, and the fix is a fresh code rather than
    /// anything the user can do on the phone.
    @MainActor
    private static func pullKeyFile(activeVersion: Int) async -> String? {
        do {
            let outcome = try await KeyFileService.shared.restoreArchivedKeys()

            // A rotated account with no key file at all. The retired keys were never backed up
            // from the browser that rotated, so they are not reachable from here by any means —
            // and saying "scan again" would send the user round a loop that cannot terminate.
            if outcome.serverHasNoKeyFile && activeVersion > 1 {
                return "Your account has \(activeVersion - 1) earlier key"
                     + (activeVersion == 2 ? "" : "s")
                     + ", but they have not been backed up to your account yet, so "
                     + "documents encrypted before your last key change will not open here. "
                     + "On the computer that holds your key, open Settings \u{203A} Encryption and "
                     + "back up your older keys, then reopen this app."
            }
            if outcome.activeIsStale {
                return "This code was made by a key that has since been replaced. Generate a new "
                     + "one on the web and scan it again, or recent documents will not open here."
            }
            if outcome.unopenable > 0 {
                return "\(outcome.unopenable) of your earlier keys could not be recovered, so "
                     + "documents encrypted with them will not open here."
            }
            if outcome.recovered > 0 {
                let plural = outcome.recovered == 1 ? "key" : "keys"
                return "\(outcome.recovered) earlier \(plural) recovered from your account, so "
                     + "documents encrypted before your last key change open here too."
            }
            return nil
        } catch {
            return "Your earlier keys could not be fetched: \(error.localizedDescription)"
        }
    }

    // MARK: - Decrypt & Import

    private func decryptAndImport(qrString: String) {
        let capturedPin = pin
        isDecrypting = true

        Task {
            do {
                // PBKDF2 runs 600 000 iterations by default, which blocks for long enough to
                // freeze the sheet if it happens on the main actor.
                let keyData = try await Task.detached(priority: .userInitiated) {
                    try KeyQRDecryptService.decrypt(qrString: qrString, pin: capturedPin)
                }.value

                let bundle = try KeyImportService.importKey(from: keyData)
                KeyImportService.storeKeys(bundle)

                // The active key is in place, which is the only thing that opens the key file.
                // A failure here is reported but must not undo the import — a device with the
                // current key and no archive still reads everything written since the last
                // rotation, and the next launch retries the pull.
                let note = await Self.pullKeyFile(activeVersion: Int(bundle.keyVersion) ?? 1)

                await MainActor.run {
                    isDecrypting = false
                    step = .success(keyVersion: bundle.keyVersion, note: note)
                }

                // Left on screen for a moment so the confirmation is actually seen.
                try? await Task.sleep(nanoseconds: 1_200_000_000)

                await MainActor.run {
                    isPresented = false
                    onImported(bundle.keyVersion, note)
                }
            } catch {
                await MainActor.run {
                    isDecrypting = false
                    step = .error(message: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - ImportStep

private enum ImportStep {
    case scanning
    case enterPin(qrString: String)
    case success(keyVersion: String, note: String?)
    case error(message: String)
}
