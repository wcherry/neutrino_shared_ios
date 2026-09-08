import SwiftUI
import NeutrinoCore
import NeutrinoCrypto

// MARK: - EncryptionSetupView

/// First-run encryption setup, shown straight after registration — the iOS counterpart of the web
/// app's `EncryptionSetupDialog`.
///
/// Shared across the apps because the identity is the account's: whichever Neutrino app a user
/// signs into first is the one that mints their key, and the kit it prints restores every other.
///
/// The key is created *for* the user: the account exists and is signed in by the time this appears,
/// so it mints the identity on appear rather than asking anything first. A new account is never
/// left holding files it cannot encrypt.
///
/// What is still asked, because it cannot be automated: the recovery kit, shown exactly once. With
/// no server-side copy of the secret key, it is the only thing that survives losing this device.
///
/// Failure is not fatal. The account is usable without a key, and Settings ▸ Encryption offers this
/// again, so "continue without it" is a real option rather than a dead end.
public struct EncryptionSetupView: View {

    @ObservedObject var service: KeyProvisioningService
    /// Called when the user has saved their kit, or chosen to move on without a key.
    let onDone: () -> Void

    public init(service: KeyProvisioningService, onDone: @escaping () -> Void) {
        self.service = service
        self.onDone = onDone
    }

    @State private var phase: Phase = .working
    @State private var recoveryKit = ""
    @State private var recoverySaved = false
    @State private var error = ""
    @State private var copied = false

    private enum Phase { case working, ready, failed }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Opaque, like `LockScreenView`: this is drawn as a layer over the app, and a recovery
            // kit is the last thing that should show through — or reach the app-switcher snapshot.
            Color(.systemBackground)
                .ignoresSafeArea()

            switch phase {
            case .working: working
            case .ready:   ready
            case .failed:  failed
            }
        }
        // Runs once. A second provisioning attempt would mint a second identity and retire the
        // first, orphaning the kit already on screen.
        .task {
            if phase == .working && recoveryKit.isEmpty { await provision() }
        }
    }

    // MARK: - Phases

    private var working: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Setting up encryption")
                .font(.title3.weight(.semibold))
            Text("Creating the key that encrypts your \(NeutrinoApp.current.contentNoun). This takes a moment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var ready: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    Text("Your \(NeutrinoApp.current.contentNoun) are encrypted with a key only you hold. It stays "
                         + "in this device\u{2019}s Keychain and is never sent to the server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Divider()

                    Text("Save your recovery kit")
                        .font(.headline)
                    Text("Your key was created on this device and never sent to us, so we cannot "
                         + "reset it. This kit is the only way back into your "
                         + "\(NeutrinoApp.current.contentNoun) if you lose "
                         + "this device. Write it down or store it somewhere safe \u{2014} it will "
                         + "not be shown again.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(recoveryKit)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Recovery kit")

                    Button {
                        UIPasteboard.general.string = recoveryKit
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Recovery Kit",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }

                    Toggle("I have saved my recovery kit somewhere safe.", isOn: $recoverySaved)
                        .font(.subheadline)
                        .padding(.top, 4)
                }
                .padding(24)
            }

            Divider()

            Button {
                // Dropped from memory as the dialog closes: it is reconstructible from the key
                // only for as long as this view holds it, and holding it longer buys nothing.
                recoveryKit = ""
                onDone()
            } label: {
                Text("Done")
                    .bold()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!recoverySaved)
            .padding(24)
        }
    }

    private var failed: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.orange)

            Text("Encryption setup")
                .font(.title3.weight(.semibold))

            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)

            Text("Your account is ready \u{2014} only the encryption key is missing. You can carry "
                 + "on and set it up later from Settings \u{25B8} Encryption.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button("Try Again") {
                    Task { await provision() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Continue Without It", action: onDone)
            }
            .padding(.top, 8)
        }
        .padding(32)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Your encryption key is ready")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func provision() async {
        phase = .working
        error = ""
        do {
            recoveryKit = try await service.provisionIdentity()
            phase = .ready
        } catch {
            self.error = error.localizedDescription
            phase = .failed
        }
    }
}

#Preview {
    EncryptionSetupView(service: KeyProvisioningService()) {}
}
