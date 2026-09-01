import Foundation
import NeutrinoCore
import LocalAuthentication
import os.log

// MARK: - BiometricEvaluating

/// Abstraction over `LAContext` so the lock state machine can be unit-tested.
///
/// `LAContext` cannot be driven from a test: there is no simulator API that produces a genuine
/// successful Face ID evaluation, and no way to synthesise a lockout. Everything interesting
/// about this feature is therefore expressed as decisions over this protocol's results, and the
/// tests inject a fake that returns canned `LAError`s.
public protocol BiometricEvaluating: AnyObject {
    var biometryType: LABiometryType { get }
    func canEvaluate(_ policy: LAPolicy) -> Result<Void, LAError>
    func evaluate(_ policy: LAPolicy, reason: String) async -> Result<Void, LAError>
}

// MARK: - LAContextEvaluator

/// Production `BiometricEvaluating`.
///
/// A **fresh `LAContext` per evaluation** is deliberate. `LAContext` caches a successful
/// evaluation for the lifetime of the instance (`touchIDAuthenticationAllowableReuseDuration`
/// defaults aside, the result itself is sticky), so reusing one across lock cycles produces the
/// classic "it let me straight back in without asking" bug — which for a security gate is a
/// silent bypass, not a cosmetic glitch.
public final class LAContextEvaluator: BiometricEvaluating {

    public init() {}

    public var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    public func canEvaluate(_ policy: LAPolicy) -> Result<Void, LAError> {
        let context = LAContext()
        var nsError: NSError?
        if context.canEvaluatePolicy(policy, error: &nsError) {
            return .success(())
        }
        if let nsError, let code = LAError.Code(rawValue: nsError.code) {
            return .failure(LAError(code))
        }
        return .failure(LAError(.biometryNotAvailable))
    }

    public func evaluate(_ policy: LAPolicy, reason: String) async -> Result<Void, LAError> {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            let ok = try await context.evaluatePolicy(policy, localizedReason: reason)
            return ok ? .success(()) : .failure(LAError(.authenticationFailed))
        } catch let error as LAError {
            return .failure(error)
        } catch {
            return .failure(LAError(.authenticationFailed))
        }
    }
}

// MARK: - BiometricAvailability

public enum BiometricAvailability: Equatable {
    case available(LABiometryType)
    case notEnrolled
    case notAvailable
    case passcodeNotSet

    /// Whether the Settings toggle may be switched on.
    public var canEnable: Bool {
        if case .available = self { return true }
        return false
    }

    public var explanation: String {
        switch self {
        case .available(.faceID):  return "Face ID is available on this device."
        case .available(.touchID): return "Touch ID is available on this device."
        case .available:           return "Biometric authentication is available on this device."
        case .notEnrolled:         return "Face ID or Touch ID is not set up. Enrol in iOS Settings to use this."
        case .passcodeNotSet:      return "Set a device passcode in iOS Settings to use this."
        case .notAvailable:        return "This device does not support Face ID or Touch ID."
        }
    }
}

// MARK: - BiometricLockError

public enum BiometricLockError: Error, Equatable {
    case cancelled
    case failed
    case lockedOut
    case unavailable
    case notEnrolled
    case passcodeNotSet

    /// Copy shown on the lock screen. Never phrased as "try again later" for `lockedOut` —
    /// `.deviceOwnerAuthentication` genuinely does offer the passcode, and telling a locked-out
    /// user to wait would strand them.
    public var message: String {
        switch self {
        case .cancelled:      return "Authentication cancelled."
        case .failed:         return "Authentication failed. Try again."
        case .lockedOut:      return "Face ID is locked. Use your device passcode to unlock."
        case .unavailable:    return "Biometric authentication is unavailable on this device."
        case .notEnrolled:    return "Face ID or Touch ID is not set up on this device."
        case .passcodeNotSet: return "Set a device passcode to use biometric lock."
        }
    }

    /// Maps an `LAError` to the user-facing outcome.
    ///
    /// Note what is *absent*: there is no case that means "let them in anyway". Every mapped
    /// value leaves the app locked; only an explicit `.success` from the evaluator unlocks it.
    public static func from(_ error: LAError) -> BiometricLockError {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:   return .cancelled
        case .biometryLockout, .touchIDLockout:        return .lockedOut
        case .biometryNotEnrolled, .touchIDNotEnrolled: return .notEnrolled
        case .biometryNotAvailable, .touchIDNotAvailable: return .unavailable
        case .passcodeNotSet:                          return .passcodeNotSet
        default:                                       return .failed
        }
    }
}
