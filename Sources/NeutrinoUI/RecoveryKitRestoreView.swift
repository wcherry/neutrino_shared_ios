import SwiftUI
import UIKit
import NeutrinoCore
import NeutrinoCrypto

// MARK: - RecoveryKitRestoreView

/// Bring an account's identity back from the printed recovery kit.
///
/// This is the path for a device that has no key and cannot get one from the web app in front of
/// it — the kit is the copy that survives losing every enrolled device, so restoring from it is the
/// only route that needs nothing but what the user wrote down.
///
/// Typing is forgiving on purpose: the kit is normalised before decoding (case, spaces, dashes, and
/// the O/0, I/L/1, U/V misreadings Crockford base32 exists to absorb), so a kit copied by eye and
/// re-typed by hand still works.
public struct RecoveryKitRestoreView: View {

    @ObservedObject var service: KeyProvisioningService
    @Binding var isPresented: Bool
    /// Called after a successful restore, so the caller can refresh what it shows about keys.
    let onRestored: () -> Void

    public init(service: KeyProvisioningService, isPresented: Binding<Bool>,
                onRestored: @escaping () -> Void) {
        self.service = service
        self._isPresented = isPresented
        self.onRestored = onRestored
    }

    @State private var kitText = ""
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var outcome: RecoveryKitRestoreOutcome?

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the recovery kit you saved when your encryption key was created. "
                         + "Spaces, dashes and capitals don\u{2019}t matter.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Recovery Kit") {
                    TextEditor(text: $kitText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .disabled(isRestoring)

                    if UIPasteboard.general.hasStrings {
                        Button {
                            kitText = UIPasteboard.general.string ?? kitText
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .disabled(isRestoring)
                    }
                }

                Section {
                    Button(action: restore) {
                        HStack {
                            Spacer()
                            if isRestoring {
                                ProgressView()
                            } else {
                                Text("Restore Key").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(isRestoring || kitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Your key is checked against your account before it is saved, so a kit "
                         + "from another account \u{2014} or from before your key was replaced "
                         + "\u{2014} is refused rather than silently leaving your "
                         + "\(NeutrinoApp.current.contentNoun) unreadable.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if let outcome {
                    Section {
                        Label("Key restored (version \(outcome.activeVersion))",
                              systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                        if outcome.archivedVersions > 0 {
                            Text("Also restored \(outcome.archivedVersions) earlier key"
                                 + (outcome.archivedVersions == 1 ? "" : "s")
                                 + ", so older \(NeutrinoApp.current.contentNoun) open here too.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if outcome.republished {
                            Text("Your account\u{2019}s key directory was empty and has been "
                                 + "restored from this kit.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Restore From Kit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                        .disabled(isRestoring)
                }
            }
        }
    }

    // MARK: - Actions

    private func restore() {
        errorMessage = nil
        outcome = nil
        isRestoring = true
        Task {
            do {
                let result = try await service.restoreFromRecoveryKit(kitText)
                outcome = result
                // The kit is not kept in a live view's state a moment longer than the restore needs
                // it, and the confirmation is left on screen long enough to be read.
                kitText = ""
                onRestored()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isRestoring = false
        }
    }
}

#Preview {
    RecoveryKitRestoreView(service: KeyProvisioningService(),
                           isPresented: .constant(true)) {}
}
