import SwiftUI
import NeutrinoCore
import NeutrinoAuth

// MARK: - RegisterView

/// Account sign-up, mirroring the web app's `/register` page: a name, an email, and a password
/// typed twice, then straight into the app on the session the sign-up mints.
///
/// Restyled from Docs' `Form` layout into the same hero shell as ``LoginView``, so the two read as
/// one flow with one identity rather than two screens that happen to be adjacent. Docs was the only
/// app that had a register screen at all; the endpoint is identical for every client id, so the
/// other four gain it by setting `supportsRegistration`.
///
/// Like ``LoginView``, nothing typed here is persisted — the credentials go to `AuthService` and
/// only the tokens it gets back reach the Keychain.
public struct RegisterView: View {

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""

    @FocusState private var focusedField: Field?

    private enum Field { case name, email, password, confirmPassword }

    /// The server's own rule (`auth/service.rs`), checked here so a too-short password costs no
    /// round trip.
    private static let minimumPasswordLength = 8

    private let brand: NeutrinoBrand

    public init(brand: NeutrinoBrand = .current) {
        self.brand = brand
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 24)

                    BrandLogo(brand: brand, size: 72)

                    Spacer().frame(height: 24)

                    Text("Create your Neutrino account")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color(.label))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Spacer().frame(height: 8)

                    Text("Free forever \u{00B7} No credit card required")
                        .font(.footnote)
                        .foregroundStyle(Color(.secondaryLabel))

                    Spacer().frame(height: 32)

                    fields

                    validationFooter
                        .padding(.horizontal, 32)
                        .padding(.top, 12)

                    Spacer().frame(height: 24)

                    actions
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Create Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(authService.isRegistering)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: authService.isRegistering)
            .animation(.easeInOut(duration: 0.2), value: authService.registerError != nil)
        }
        // The account is made and signed into in one go, so this sheet's job is done the moment a
        // session exists.
        .onChange(of: authService.isAuthenticated) { authenticated in
            if authenticated { dismiss() }
        }
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(spacing: 12) {
            TextField("Your name", text: $name)
                .textContentType(.name)
                .focused($focusedField, equals: .name)
                .submitLabel(.next)
                .onSubmit { focusedField = .email }
                .brandFieldStyle()

            TextField("you@example.com", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
                .brandFieldStyle()

            BrandPasswordField("At least \(Self.minimumPasswordLength) characters",
                               text: $password,
                               focus: $focusedField,
                               field: .password,
                               contentType: .newPassword,
                               submitLabel: .next) {
                focusedField = .confirmPassword
            }

            BrandPasswordField("Re-enter your password",
                               text: $confirmPassword,
                               focus: $focusedField,
                               field: .confirmPassword,
                               contentType: .newPassword,
                               submitLabel: .go) {
                submit()
            }
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Validation

    /// Only flagged once the user has typed something to compare against, so the field is not
    /// complaining the moment it gains focus.
    private var mismatch: Bool {
        !confirmPassword.isEmpty && password != confirmPassword
    }

    private var tooShort: Bool {
        !password.isEmpty && password.count < Self.minimumPasswordLength
    }

    @ViewBuilder
    private var validationFooter: some View {
        // One line at a time, worst first: two red messages about the same pair of fields read as
        // two separate problems.
        if let error = authService.registerError {
            InlineError(error)
        } else if tooShort {
            InlineError("Password must be at least \(Self.minimumPasswordLength) characters.")
        } else if mismatch {
            InlineError("Passwords do not match.")
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 14) {
            BrandButton("Create Free Account",
                        isBusy: authService.isRegistering,
                        isEnabled: canSubmit,
                        brand: brand,
                        action: submit)

            // Said before they sign up rather than after, because the recovery kit that follows is
            // shown once and is the only copy of the key.
            Text("Your files are end-to-end encrypted. Your key is created on this device right "
                 + "after you sign up, and you\u{2019}ll be shown a recovery kit to save.")
                .font(.system(size: 12))
                .foregroundStyle(Color(.tertiaryLabel))
                .multilineTextAlignment(.center)

            // The same account exists on whichever server the login screen is pointed at, so
            // sign-up honours that choice rather than quietly using the default.
            Text("Server: \(NeutrinoStorage.serverHost)")
                .font(.system(size: 11))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 48)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }

    private var canSubmit: Bool {
        !authService.isRegistering
            && !trimmedName.isEmpty
            && !trimmedEmail.isEmpty
            && password.count >= Self.minimumPasswordLength
            && password == confirmPassword
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task {
            await authService.register(name: trimmedName, email: trimmedEmail, password: password)
            // Cleared whether or not the attempt succeeded — a failed sign-up should not leave the
            // password sitting in a live view's state.
            password = ""
            confirmPassword = ""
        }
    }
}
