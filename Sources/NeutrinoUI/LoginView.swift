import SwiftUI
import NeutrinoCore
import NeutrinoAuth

// MARK: - LoginView

/// The sign-in screen, shared by every Neutrino iOS app.
///
/// One screen replaces five. Drive and Notes had this hero layout; Docs, Sheets and Photos had a
/// `Form`. What differs per app is `NeutrinoBrand` — a title, a logo, a gradient, three trust rows
/// — and nothing else.
///
/// Behaviour is the union of what the five copies did, not the intersection:
///
/// - **Two-factor** (Drive only) shows the code field once the server asks for it.
/// - **Create Account** (Docs only) presents ``RegisterView``.
/// - **Password clearing** (Docs, Sheets, Photos) wipes the field after every attempt, successful
///   or not — a failed sign-in should not leave a password sitting in live view state.
/// - **Focus chaining** (Docs, Sheets, Photos) moves email → password → submit off the keyboard.
/// - **Device naming** (Docs, Sheets, Photos) tells the user what the account's device list will
///   show, next to the server field that determines which account it is.
///
/// Both optional behaviours are gated on `NeutrinoAppConfig`, so an app adopts them when its
/// screens have been through QA rather than the day it links this package.
///
/// Credentials go straight to `AuthService` and are never held in the Keychain, `UserDefaults`, or
/// anywhere else; only the tokens the exchange returns are persisted.
public struct LoginView: View {

    @EnvironmentObject private var authService: AuthService

    @State private var serverHost: String = NeutrinoStorage.serverHost
    @State private var email = ""
    @State private var password = ""
    @State private var totpCode = ""
    @State private var showServerField = false
    @State private var showRegister = false

    @FocusState private var focusedField: Field?

    private enum Field { case email, password, totp, server }

    private let brand: NeutrinoBrand

    public init(brand: NeutrinoBrand = .current) {
        self.brand = brand
    }

    private var config: NeutrinoAppConfig { NeutrinoApp.current }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 60)

                BrandLogo(brand: brand)

                Spacer().frame(height: 32)

                Text(brand.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color(.label))
                    .multilineTextAlignment(.center)

                Spacer().frame(height: 10)

                Text(brand.tagline)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 48)

                TrustRowCarousel(rows: brand.trustRows)
                    .padding(.horizontal, 40)

                Spacer().frame(height: 40)

                credentialFields

                if let error = authService.loginError {
                    InlineError(error)
                        .padding(.horizontal, 32)
                        .padding(.top, 12)
                }

                Spacer().frame(height: 24)

                actions
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(.easeInOut(duration: 0.2), value: authService.isLoggingIn)
        .animation(.easeInOut(duration: 0.2), value: authService.loginError != nil)
        .animation(.easeInOut(duration: 0.2), value: authService.requiresTwoFactorCode)
        .sheet(isPresented: $showRegister) {
            RegisterView(brand: brand)
                .environmentObject(authService)
        }
    }

    // MARK: - Fields

    private var credentialFields: some View {
        VStack(spacing: 12) {
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
                .brandFieldStyle()

            BrandPasswordField("Password",
                               text: $password,
                               focus: $focusedField,
                               field: .password,
                               contentType: .password,
                               submitLabel: authService.requiresTwoFactorCode ? .next : .go) {
                if authService.requiresTwoFactorCode { focusedField = .totp } else { submit() }
            }

            // Shown only once the server has said this account has two-factor enabled — asking
            // every account for a code it does not have would be worse than not asking at all.
            if config.supportsTwoFactor && authService.requiresTwoFactorCode {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: 20)
                    TextField("Authentication code", text: $totpCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .totp)
                }
                .brandFieldStyle()
                .transition(.opacity)
            }

            DisclosureGroup(isExpanded: $showServerField) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("https://neutrino.example.com", text: $serverHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .server)
                        .onChange(of: serverHost) { newValue in
                            // Writes the App Group suite as well as `.standard`, so an app with a
                            // share extension resolves the same host from both binaries.
                            NeutrinoStorage.setServerHost(newValue)
                        }
                        .brandFieldStyle()

                    // Naming the device here is honest about what signing in registers, and matches
                    // what the account's device list will show.
                    Text("This device will register as \u{201C}\(DeviceIdentity.deviceName)\u{201D}.")
                        .font(.footnote)
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: 20)
                    Text("Server")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            .tint(Color(.secondaryLabel))
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 14) {
            BrandButton("Sign In",
                        icon: "person.badge.shield.checkmark.fill",
                        isBusy: authService.isLoggingIn,
                        isEnabled: canSubmit,
                        brand: brand,
                        action: submit)

            if config.supportsRegistration {
                Button("Create Account") { showRegister = true }
                    .font(.system(size: 16, weight: .medium))
                    .tint(brand.accent)
                    .disabled(authService.isLoggingIn)
            }

            Text("By signing in you agree to our Terms of Service and Privacy Policy.")
                .font(.system(size: 12))
                .foregroundStyle(Color(.tertiaryLabel))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 48)
    }

    private var canSubmit: Bool {
        guard !authService.isLoggingIn,
              !email.trimmingCharacters(in: .whitespaces).isEmpty,
              !password.isEmpty,
              !serverHost.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        // Once the server has asked for the second factor, a code is part of the credentials.
        return !authService.requiresTwoFactorCode || !totpCode.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task {
            await authService.login(email: email.trimmingCharacters(in: .whitespaces),
                                    password: password,
                                    totpCode: totpCode)
            // Cleared whether or not the attempt succeeded — a failed login should not leave the
            // password sitting in a live view's state. The 2FA code is cleared too: it is
            // single-use, and a stale one in the field guarantees the retry fails.
            password = ""
            totpCode = ""
        }
    }
}
