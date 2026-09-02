import SwiftUI
import UniformTypeIdentifiers
import VisionKit
import NeutrinoCore
import NeutrinoCrypto

// MARK: - KeyImportView

/// Import the account's end-to-end encryption key: pick the JSON file the Neutrino web app
/// exports, scan its PIN-protected QR code, or paste the JSON directly. The validated pair goes
/// straight to the Keychain, and the account's retired keys are pulled down behind it.
///
/// `showQRScan` replaces each app's own `FeatureFlags.qrKeyScan`, which is the only thing the
/// five copies of this screen disagreed about.
///
/// Presented either way: Docs and Sheets show it as a sheet bound to an `isPresented` flag, Photos
/// pushes it onto a `NavigationStack`. Hence the optional binding — `dismiss()` handles both, and
/// the binding is written back only when a caller supplied one.
public struct KeyImportView: View {

    private let isPresented: Binding<Bool>?

    private let showQRScan: Bool

    public init(isPresented: Binding<Bool>? = nil, showQRScan: Bool = true) {
        self.isPresented = isPresented
        self.showQRScan = showQRScan
    }

    @Environment(\.dismiss) private var dismiss

    /// Closes the screen however it was presented.
    private func close() {
        isPresented?.wrappedValue = false
        dismiss()
    }

    @State private var showFilePicker = false
    @State private var showQRScanner = false
    @State private var pastedText = ""
    @State private var errorMessage: String?
    @State private var importedVersion: String?
    /// What the key-file pull recovered, when it recovered anything worth saying.
    @State private var archiveMessage: String?

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your encryption key never leaves this device. It is stored in the Keychain and used to decrypt your documents locally.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Import From File") {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Choose Key File…", systemImage: "folder")
                    }
                }

                if showQRScan {
                    Section {
                        Button {
                            showQRScanner = true
                        } label: {
                            Label("Scan QR Code…", systemImage: "qrcode.viewfinder")
                        }
                        .disabled(!DataScannerViewController.isSupported)
                    } header: {
                        Text("Or Scan QR Code")
                    } footer: {
                        Text(DataScannerViewController.isSupported
                             ? "Scan the key QR code from the Neutrino web app, then enter the PIN protecting it."
                             : "QR scanning isn't supported on this device.")
                    }
                }

                Section("Or Paste Key JSON") {
                    TextEditor(text: $pastedText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Import Pasted Key") {
                        importPasted()
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if let importedVersion {
                    Section {
                        Label("Key imported (version \(importedVersion))", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                        if let archiveMessage {
                            Text(archiveMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Import Encryption Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }
                }
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.json, .plainText],
                          allowsMultipleSelection: false) { result in
                handleFileImport(result)
            }
            .sheet(isPresented: $showQRScanner) {
                KeyQRImportView(isPresented: $showQRScanner) { keyVersion, note in
                    // The QR sheet already stored the bundle and pulled the key file; this only
                    // mirrors the confirmation and closes the import sheet behind it.
                    errorMessage = nil
                    importedVersion = keyVersion
                    archiveMessage = note
                    Task {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        close()
                    }
                }
            }
        }
    }

    // MARK: - Import

    private func handleFileImport(_ result: Result<[URL], Error>) {
        errorMessage = nil
        archiveMessage = nil
        do {
            guard let url = try result.get().first else { return }
            // A file picked from Files is outside the app's sandbox until this is granted, and the
            // read fails silently without it.
            let needsRelease = url.startAccessingSecurityScopedResource()
            defer { if needsRelease { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            try store(data)
        } catch let error as KeyImportError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPasted() {
        errorMessage = nil
        archiveMessage = nil
        do {
            try store(Data(pastedText.utf8))
        } catch let error as KeyImportError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func store(_ data: Data) throws {
        let bundle = try KeyImportService.importKey(from: data)
        KeyImportService.storeKeys(bundle)
        importedVersion = bundle.keyVersion
        pastedText = ""
        // Left on screen for a moment so the confirmation is actually seen before the sheet goes.
        Task {
            await pullKeyFile()
            try? await Task.sleep(nanoseconds: 800_000_000)
            close()
        }
    }

    /// Bring the account's retired keys across, now that this device holds the key that opens them.
    ///
    /// A failure is shown but does not undo the import: the active key alone still reads everything
    /// written since the last rotation, and the pull is retried on the next launch. Refusing the
    /// whole enrolment over a network error would be the worse trade.
    @MainActor
    private func pullKeyFile() async {
        do {
            let outcome = try await KeyFileService.shared.restoreArchivedKeys()
            if outcome.activeIsStale {
                errorMessage = "This key has since been replaced on your account. Documents written "
                    + "after it was replaced will not open here — import your current key instead."
            } else if outcome.recovered > 0 {
                archiveMessage = "Also recovered \(outcome.recovered) earlier key"
                    + (outcome.recovered == 1 ? "" : "s")
                    + " from your account, so older documents open here too."
            }
        } catch {
            errorMessage = "Your key was imported, but your earlier keys could not be fetched: "
                + error.localizedDescription
        }
    }
}
