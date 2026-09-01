import Foundation
import LocalAuthentication
import os.log
import NeutrinoCore

// MARK: - BiometricAuthService

/// Opt-in Face ID / Touch ID gate on app launch and on encryption-key access.
///
/// ## Policy
///
/// Uses `LAPolicy.deviceOwnerAuthentication`, **not** `.deviceOwnerAuthenticationWithBiometrics`.
/// The biometrics-only policy fails hard on biometry lockout and leaves the user with no route
/// back into their own encrypted content short of deleting the app. `.deviceOwnerAuthentication`
/// falls back to the device passcode automatically. `canEvaluate` is still probed against the
/// biometrics-only policy at *enable* time, so Settings can honestly say "Face ID is not set up"
/// rather than quietly enrolling the user in a passcode-only gate.
///
/// ## Lock vs. obscure
///
/// `isLocked` and `isObscured` are separate on purpose. The app-switcher snapshot is taken on
/// `scenePhase == .inactive`, which fires *before* `.background`, so a grace-period check alone
/// would leak file names into the switcher for anyone with a non-zero grace period. `isObscured`
/// is set on `.inactive` unconditionally; `isLocked` is set on return to `.active` only if the
/// grace period has lapsed.
///
/// ## What changed on the way into the package
///
/// Drive, Docs and Sheets each carried this file; the three differed only in comment wrapping and
/// two literals. Those literals are now injected — `isFeatureEnabled` in place of each app's own
/// `FeatureFlags.biometricLock`, and `unlockReason` / `keyAccessReason` in place of hardcoded
/// "Neutrino Drive" / "your encrypted files" copy.
@MainActor
public final class BiometricAuthService: ObservableObject {

    // MARK: - UserDefaults keys

    public enum Keys {
        public static let enabled            = "biometricLock.enabled"
        public static let gracePeriodSeconds = "biometricLock.gracePeriodSeconds"
    }

    /// Selectable grace periods, in seconds. Default is 60 — an immediate re-lock is genuinely
    /// useful for the paranoid and genuinely infuriating for everyone else.
    public static let gracePeriodOptions: [TimeInterval] = [0, 60, 300, 900]
    public static let defaultGracePeriod: TimeInterval = 60

    // MARK: - Published state

    /// True when the lock screen must block access to app content.
    @Published public private(set) var isLocked: Bool = false

    /// True while the app is inactive/backgrounded — covers the app-switcher snapshot.
    @Published public private(set) var isObscured: Bool = false

    /// Result of the most recent failed authentication, for lock-screen copy.
    @Published public private(set) var lastError: BiometricLockError?

    /// True while an evaluation is in flight, so the lock screen can disable its retry button.
    @Published public private(set) var isAuthenticating: Bool = false

    /// Bound by the settings toggle. Turning it on probes availability first and reverts to
    /// `false` when biometrics are unusable, so the toggle never lies about being on.
    @Published public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }

            // A refused enable writes `false` back to this same property, re-entering `didSet`.
            // Without this guard the re-entrant pass takes the "user turned it off" branch and
            // clears `lastError` — wiping the very explanation the refusal just recorded, so the
            // toggle would silently flip back with no reason given.
            if isRevertingEnable {
                isRevertingEnable = false
                return
            }

            if isEnabled {
                let availability = availability()
                guard availability.canEnable else {
                    logger.info("enable refused: \(String(describing: availability), privacy: .public)")
                    lastError = Self.enableError(for: availability)
                    isRevertingEnable = true
                    isEnabled = false
                    return
                }
            }
            defaults.set(isEnabled, forKey: Keys.enabled)
            if !isEnabled {
                isLocked = false
                lastError = nil
            }
        }
    }

    private var isRevertingEnable = false

    // MARK: - Settings

    public var gracePeriod: TimeInterval {
        get {
            guard let stored = defaults.object(forKey: Keys.gracePeriodSeconds) as? Double else {
                return Self.defaultGracePeriod
            }
            return stored
        }
        set { defaults.set(newValue, forKey: Keys.gracePeriodSeconds) }
    }

    public var biometryType: LABiometryType { evaluator.biometryType }

    /// "Face ID" / "Touch ID" / "Biometrics" — for user-facing copy.
    public var biometryName: String {
        switch evaluator.biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        default:       return "Biometrics"
        }
    }

    // MARK: - Private

    private let defaults: UserDefaults
    private let evaluator: BiometricEvaluating
    private let logger: Logger

    /// Each app's own kill switch, passed in rather than read from a `FeatureFlags` this package
    /// cannot see. `false` reports every gate as passed, so a disabled feature never prompts and
    /// never blocks.
    private let isFeatureEnabled: Bool

    private let unlockReason: String
    private let keyAccessReason: String

    /// When the app last went to `.background`. `nil` means "not backgrounded since launch".
    public private(set) var lastBackgroundedAt: Date?

    /// When the user last authenticated successfully. Drives the key-access short-circuit.
    public private(set) var lastAuthenticatedAt: Date?

    /// Injectable clock so the grace-period tests don't sleep.
    public var now: () -> Date = { Date() }

    // MARK: - Init

    public init(defaults: UserDefaults = .standard,
                evaluator: BiometricEvaluating = LAContextEvaluator(),
                isFeatureEnabled: Bool = true,
                unlockReason: String? = nil,
                keyAccessReason: String = "Authenticate to access your encryption keys.") {
        self.defaults = defaults
        self.evaluator = evaluator
        self.isFeatureEnabled = isFeatureEnabled
        self.unlockReason = unlockReason ?? "Unlock \(NeutrinoApp.current.displayName) to continue."
        self.keyAccessReason = keyAccessReason
        self.logger = Logger(subsystem: NeutrinoApp.current.logSubsystem,
                             category: "BiometricAuthService")
        self.isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
    }

    // MARK: - Availability

    public func availability() -> BiometricAvailability {
        guard isFeatureEnabled else { return .notAvailable }
        switch evaluator.canEvaluate(.deviceOwnerAuthenticationWithBiometrics) {
        case .success:
            return .available(evaluator.biometryType)
        case .failure(let error):
            switch error.code {
            case .biometryNotEnrolled, .touchIDNotEnrolled: return .notEnrolled
            case .passcodeNotSet:                           return .passcodeNotSet
            default:                                        return .notAvailable
            }
        }
    }

    private static func enableError(for availability: BiometricAvailability) -> BiometricLockError {
        switch availability {
        case .notEnrolled:    return .notEnrolled
        case .passcodeNotSet: return .passcodeNotSet
        default:              return .unavailable
        }
    }

    // MARK: - Lock decision (pure — the part that is actually testable)

    /// Whether returning to the foreground should re-lock the app.
    ///
    /// `lastBackgroundedAt == nil` means the app has not been backgrounded since launch, which is
    /// not a reason to lock — cold-launch locking is handled by ``lockOnLaunch()``.
    public static func shouldLock(lastBackgroundedAt: Date?, now: Date, gracePeriod: TimeInterval) -> Bool {
        guard let lastBackgroundedAt else { return false }
        return now.timeIntervalSince(lastBackgroundedAt) >= gracePeriod
    }

    // MARK: - Lifecycle

    /// Locks the app at cold launch when the feature is on. Called once from the app's `.task`.
    public func lockOnLaunch() {
        guard isFeatureEnabled, isEnabled else {
            isLocked = false
            return
        }
        isLocked = true
        lastError = nil
    }

    /// `scenePhase == .inactive` — the moment iOS takes the app-switcher snapshot. Obscuring here
    /// (rather than on `.background`) is what stops content leaking into the switcher.
    public func sceneDidBecomeInactive() {
        guard isFeatureEnabled, isEnabled else { return }
        isObscured = true
    }

    public func sceneDidEnterBackground() {
        guard isFeatureEnabled, isEnabled else { return }
        isObscured = true
        // The Face ID system prompt itself drops the scene to `.background` and back while an
        // unlock is already in flight. Recording that as a fresh backgrounding would hand
        // `sceneDidBecomeActive()` a timestamp to re-lock against the instant the real unlock
        // succeeds — an unlock-then-instantly-relock cycle that repeats forever. Only a background
        // that starts from an *unlocked* app is a genuine backgrounding.
        guard !isLocked else { return }
        lastBackgroundedAt = now()
    }

    /// `scenePhase == .active`. Clears the switcher obscuring and re-locks if the grace period has
    /// lapsed.
    public func sceneDidBecomeActive() {
        guard isFeatureEnabled, isEnabled else {
            isObscured = false
            isLocked = false
            return
        }
        isObscured = false
        // Mirrors the guard in `sceneDidEnterBackground()`: while already locked (including
        // mid-authentication) there is no decision to make, and re-running `shouldLock` here is
        // what turns the Face ID prompt's own scene transitions into an infinite re-lock loop.
        guard !isLocked, let backgroundedAt = lastBackgroundedAt else { return }
        if Self.shouldLock(lastBackgroundedAt: backgroundedAt, now: now(), gracePeriod: gracePeriod) {
            isLocked = true
            lastError = nil
        }
        lastBackgroundedAt = nil
    }

    /// True when the lock overlay should be on screen.
    public var shouldPresentOverlay: Bool { isLocked || isObscured }

    // MARK: - Authentication

    /// Attempts to unlock. Returns whether the app is now unlocked.
    ///
    /// The invariant this method exists to hold: **no failure path unlocks.** Cancel, lockout, and
    /// authentication failure all leave `isLocked == true` with `lastError` populated.
    @discardableResult
    public func unlock() async -> Bool {
        guard isFeatureEnabled, isEnabled else {
            isLocked = false
            return true
        }
        guard !isAuthenticating else { return !isLocked }

        isAuthenticating = true
        defer { isAuthenticating = false }

        switch await evaluate(reason: unlockReason) {
        case .success:
            isLocked = false
            lastError = nil
            lastAuthenticatedAt = now()
            return true
        case .failure(let error):
            lastError = error
            isLocked = true
            return false
        }
    }

    /// Gate in front of encryption-key access. Short-circuits to success when the user
    /// authenticated within the grace period — re-prompting someone who unlocked two seconds ago
    /// is friction with no security value.
    ///
    /// Deliberately **not** applied to every upload/download: those run unattended (photo
    /// auto-sync, background transfers), where a biometric prompt is either impossible or a
    /// guaranteed failure. The honest boundary is "the app is locked", not "every operation is
    /// individually attested".
    @discardableResult
    public func authenticateForKeyAccess() async -> Bool {
        guard isFeatureEnabled, isEnabled else { return true }

        if let lastAuthenticatedAt,
           now().timeIntervalSince(lastAuthenticatedAt) < gracePeriod {
            return true
        }

        switch await evaluate(reason: keyAccessReason) {
        case .success:
            lastAuthenticatedAt = now()
            lastError = nil
            return true
        case .failure(let error):
            lastError = error
            return false
        }
    }

    /// Runs the policy evaluation, retrying once with the passcode-capable policy when the user
    /// explicitly asks for the fallback.
    private func evaluate(reason: String) async -> Result<Void, BiometricLockError> {
        // `.deviceOwnerAuthentication` already presents the passcode sheet on biometric failure,
        // so this single call covers the fallback for almost every case.
        switch await evaluator.evaluate(.deviceOwnerAuthentication, reason: reason) {
        case .success:
            return .success(())
        case .failure(let error):
            if error.code == .userFallback {
                // The user tapped "Enter Passcode" against a biometrics-only prompt (possible when
                // the system downgrades the policy). Re-evaluate explicitly.
                switch await evaluator.evaluate(.deviceOwnerAuthentication, reason: reason) {
                case .success: return .success(())
                case .failure(let retryError): return .failure(.from(retryError))
                }
            }
            return .failure(.from(error))
        }
    }

    // MARK: - Test seams

    #if DEBUG
    public func debugSetLastBackgroundedAt(_ date: Date?) { lastBackgroundedAt = date }
    public func debugSetLastAuthenticatedAt(_ date: Date?) { lastAuthenticatedAt = date }
    public func debugSetLocked(_ locked: Bool) { isLocked = locked }
    #endif
}
