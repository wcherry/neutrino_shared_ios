import SwiftUI
import VisionKit
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto

// MARK: - KeyringQRImportView
//
// Enrolling this device by scanning the web app's key code, on the keyring storage model.
//
// The sibling of `KeyQRImportView`, which does the same job for an app on the split store. Same
// scan, same PIN, same envelope; the difference is where the key lands and therefore what the
// caller gets back. This one binds the key to an account (`KeyringStore` keys are per-user), so it
// needs an `AuthService` in the environment and reports a `KeyFileRestoreOutcome` rather than a
// pre-rendered sentence. See the note on the two models in `Keyring.swift`.
//
// Three steps: scan the QR, type the six digits shown beside it, then install what comes out. The
// third step is two installs, not one — the code carries the account's *active* key, and the
// account's retired keys are then pulled from the key file (`KeyFileService`) and unsealed with it.
// Doing only the first would leave a device that opens everything written since the last rotation
// and nothing written before it.
//
// The recovery kit path is the stronger one: it carries every version and never touches the
// network. This exists because it is what the web app offers, and because a phone is the device
// with the camera.

public struct KeyringQRImportView: View {

    @Binding private var isPresented: Bool
    /// Called once the keyring is on this device, so the presenter can refresh.
    private let onImported: () -> Void

    public init(isPresented: Binding<Bool>, onImported: @escaping () -> Void = {}) {
        self._isPresented = isPresented
        self.onImported = onImported
    }

    @EnvironmentObject private var authService: AuthService

    @State private var step: Step = .scanning
    @State private var pin = ""
    @State private var isWorking = false

    public var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .scanning:
                    scanningView
                case .enterPin(let payload):
                    pinEntryView(payload: payload)
                case .success(let version, let outcome):
                    successView(version: version, outcome: outcome)
                case .failure(let message):
                    failureView(message: message)
                }
            }
            .navigationTitle("Scan key code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
    }

    private var scanningView: some View {
        Group {
            // Unsupported on the Simulator and on devices without a Neural Engine. The recovery kit
            // path remains, so this is a dead end rather than a failure.
            if DataScannerViewController.isSupported {
                ZStack(alignment: .bottom) {
                    QRScannerView { payload in
                        DispatchQueue.main.async {
                            pin = ""
                            step = .enterPin(payload: payload)
                        }
                    }
                    .ignoresSafeArea(edges: .top)

                    Text("In Neutrino on the web, open Settings → Encryption and choose "
                         + "“Key code for mobile”. Point the camera at the code it shows.")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                }
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("This device cannot scan QR codes.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Restore from your recovery kit instead.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(32)
            }
        }
    }

    private func pinEntryView(payload: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("Enter the PIN")
                .font(.title2)
                .fontWeight(.semibold)

            Text("The web page shows six digits beside the code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .padding(.horizontal, 32)

            if isWorking {
                ProgressView()
                    .padding(.top, 8)
            } else {
                Button {
                    Task { await install(payload: payload) }
                } label: {
                    Text("Import key")
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

    private func successView(version: Int, outcome: KeyFileRestoreOutcome) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("Key imported (version \(version))")
                .font(.headline)

            // The pull is the part that decides whether older files open, so its result is stated
            // rather than left for the user to discover one unreadable file at a time.
            if let note = Self.archiveNote(for: outcome, activeVersion: version) {
                Text(note.text)
                    .font(.subheadline)
                    .foregroundStyle(note.isWarning ? Color.orange : Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button("Done") {
                isPresented = false
                onImported()
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)

            Text("Import failed")
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
                Text("Try again")
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

    // MARK: - Reporting the pull

    /// What to say about the key file, if anything.
    ///
    /// Built here rather than inline so the branches stay readable and the view body stays cheap to
    /// type-check. The app's own word for what it holds (`contentNoun`) goes in, because "documents
    /// encrypted before your last key change will not open here" is the sentence a Docs user needs
    /// and "your content" is not.
    static func archiveNote(for outcome: KeyFileRestoreOutcome, activeVersion: Int)
    -> (text: String, isWarning: Bool)? {
        let noun = NeutrinoApp.current.contentNoun

        // A rotated account with no key file at all. The retired keys were never backed up from the
        // browser that rotated, so they are not reachable from here by any means — and saying "scan
        // again" would send the user round a loop that cannot terminate.
        if outcome.serverHasNoKeyFile && activeVersion > 1 {
            let count = activeVersion - 1
            return ("Your account has \(count) earlier key\(count == 1 ? "" : "s"), but they have "
                    + "not been backed up to your account yet, so \(noun) encrypted before your "
                    + "last key change will not open here. On the computer that holds your key, "
                    + "open Settings \u{203A} Encryption and back up your older keys, then reopen "
                    + "this app.", true)
        }
        // The code always carries the account's current key, so a version in the file that we think
        // is current means the *page* was stale — the browser built the code before a rotation it
        // has not caught up with.
        if outcome.activeIsStale {
            return ("This code was made by a key that has since been replaced. Generate a new "
                    + "one on the web and scan it again.", true)
        }
        if outcome.unopenable > 0 {
            return ("\(outcome.unopenable) of your earlier keys could not be recovered, so \(noun) "
                    + "encrypted with them will not open here.", true)
        }
        if outcome.recovered > 0 {
            let plural = outcome.recovered == 1 ? "key" : "keys"
            return ("\(outcome.recovered) earlier \(plural) recovered from your account, so "
                    + "\(noun) encrypted before your last key change open here too.", false)
        }
        return nil
    }

    // MARK: - Install

    @MainActor
    private func install(payload: String) async {
        let enteredPin = pin
        isWorking = true
        defer { isWorking = false }

        guard let userId = await authService.currentUserID() else {
            step = .failure(message: "You are signed out. Sign in and try again.")
            return
        }

        do {
            // 600 000 rounds of PBKDF2 is about a second on a phone, which is long enough to freeze
            // the sheet if it runs on the main actor.
            let keyData = try await Task.detached(priority: .userInitiated) {
                try KeyQRDecryptService.decrypt(qrString: payload, pin: enteredPin)
            }.value

            let bundle = try KeyImportService.importKey(from: keyData)
            guard KeyImportService.storeKeys(bundle, userId: userId) else {
                step = .failure(message: "Could not save the key to this device.")
                return
            }
            pin = ""

            // The active key is in place, which is what opens the key file. A failure here is
            // reported but must not undo the import: a device with the current key and no archive
            // still reads everything written since the last rotation, and the pull can be retried.
            var outcome = KeyFileRestoreOutcome()
            do {
                outcome = try await KeyFileService.shared.restoreArchivedKeys(using: authService)
            } catch {
                step = .success(version: Int(bundle.keyVersion) ?? 1, outcome: outcome)
                onImported()
                return
            }

            step = .success(version: Int(bundle.keyVersion) ?? 1, outcome: outcome)
            onImported()
        } catch {
            step = .failure(message: error.localizedDescription)
        }
    }
}

// MARK: - Step

private enum Step {
    case scanning
    case enterPin(payload: String)
    case success(version: Int, outcome: KeyFileRestoreOutcome)
    case failure(message: String)
}
