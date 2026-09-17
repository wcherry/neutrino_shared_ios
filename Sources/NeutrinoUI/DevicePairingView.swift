import SwiftUI
import CoreImage.CIFilterBuiltins
import NeutrinoAuth
import NeutrinoCrypto

// MARK: - DevicePairingView
//
// The receiving half of the two-QR handshake. This device shows QR-A, the other device scans it and
// shows QR-B, this device scans that back.
//
// The old flow was one QR carrying the whole keypair behind a short PIN, which meant anyone who
// photographed the screen held the identity after a few seconds of offline guessing. Here the first
// code is only a public key: photographing either code yields nothing without the ephemeral secret
// half, which never leaves this device.
//
// The confirmation code at the end is the one step that cannot be skipped. A passive photographer
// is already defeated; an *active* relay — someone showing their own QR-A to the sender and
// re-sealing to us — is not, and the code is what exposes them, because it is derived from a
// transcript a relay cannot make agree on both ends. So the final screen asks the user to compare,
// and says what a mismatch means.
//
// Requires the app to be on the keyring storage model: the recovered keyring lands in
// `KeyringStore`, which a split-store app does not read. See the note in `Keyring.swift`.

public struct DevicePairingView: View {

    @Binding private var isPresented: Bool
    private let onPaired: () -> Void

    public init(isPresented: Binding<Bool>, onPaired: @escaping () -> Void = {}) {
        self._isPresented = isPresented
        self.onPaired = onPaired
    }

    @EnvironmentObject private var authService: AuthService

    private enum Step {
        case showingOffer
        case scanning
        case confirming(code: String, keyring: Keyring)
    }

    @State private var step: Step = .showingOffer
    @State private var session: PairingSession?
    @State private var errorMessage: String?

    public var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .showingOffer:   offerStep
                case .scanning:       scanningStep
                case .confirming(let code, let keyring):
                    confirmStep(code: code, keyring: keyring)
                }
            }
            .navigationTitle("Pair with a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session?.close()
                        isPresented = false
                    }
                }
            }
        }
        .onAppear {
            if session == nil { session = Pairing.createSession() }
        }
        .onDisappear { session?.close() }
    }

    // MARK: Step 1 — show QR-A

    private var offerStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("On the device that has your key, open Settings → Your key → Add a device, "
                     + "and scan this code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let session, let payload = try? Pairing.encode(session.offer),
                   let image = Self.qrImage(from: payload) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .padding()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView()
                }

                Text("This code is not secret — it only tells the other device where to send "
                     + "your key. Nothing is sent through our servers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    step = .scanning
                } label: {
                    Label("Scan their reply", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: Step 2 — scan QR-B

    private var scanningStep: some View {
        QRScannerView { payload in
            handleScan(payload)
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .bottom) {
            Text("Scan the code now showing on the other device.")
                .font(.footnote)
                .padding()
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 32)
        }
    }

    // MARK: Step 3 — compare the confirmation code

    private func confirmStep(code: String, keyring: Keyring) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Confirmation code")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(code)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .kerning(6)

                Text("Check that the other device shows this same code. If the codes differ, "
                     + "something is intercepting the transfer — stop and try again on a "
                     + "different network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Text(keyring.entries.count == 1
                     ? "1 key version will be saved to this device."
                     : "\(keyring.entries.count) key versions will be saved to this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    accept(keyring)
                } label: {
                    Text("The codes match — save my key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

                Button(role: .destructive) {
                    session?.close()
                    isPresented = false
                } label: {
                    Text("They don’t match")
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 32)
        }
    }

    // MARK: Actions

    private func handleScan(_ payload: String) {
        guard let session else { return }
        do {
            let response = try Pairing.parseResponse(payload)
            // The account check happens here, before anything is shown as acceptable — a keyring
            // for a different account must not reach the confirmation screen at all.
            Task { @MainActor in
                guard let userId = await authService.currentUserID() else {
                    errorMessage = "You are signed out. Sign in and try again."
                    step = .showingOffer
                    return
                }
                do {
                    let keyring = try Pairing.accept(response, session: session, userId: userId)
                    let code = Pairing.confirmationCode(offer: session.offer, response: response)
                    step = .confirming(code: code, keyring: keyring)
                } catch {
                    errorMessage = error.localizedDescription
                    step = .showingOffer
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            step = .showingOffer
        }
    }

    @MainActor
    private func accept(_ keyring: Keyring) {
        guard KeyringStore.shared.store(keyring) else {
            errorMessage = "Could not save the key to this device."
            step = .showingOffer
            return
        }
        session?.close()
        onPaired()
        isPresented = false
    }

    // MARK: QR rendering

    private static func qrImage(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Medium correction: the payload is a sealed keyring and can run to a few hundred bytes, so
        // the extra redundancy of higher levels would push the code denser than a phone camera
        // reads comfortably.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
