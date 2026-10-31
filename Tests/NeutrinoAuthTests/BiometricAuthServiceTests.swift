import LocalAuthentication
import XCTest
import NeutrinoCore
@testable import NeutrinoAuth

/// A device with no biometrics: only the passcode (or a Mac's password) can authenticate.
private final class PasscodeOnlyEvaluator: BiometricEvaluating {
    var passcodeSet = true
    var biometryType: LABiometryType { .none }
    func canEvaluate(_ policy: LAPolicy) -> Result<Void, LAError> {
        if policy == .deviceOwnerAuthenticationWithBiometrics { return .failure(LAError(.biometryNotAvailable)) }
        return passcodeSet ? .success(()) : .failure(LAError(.passcodeNotSet))
    }
    func evaluate(_ policy: LAPolicy, reason: String) async -> Result<Void, LAError> {
        passcodeSet ? .success(()) : .failure(LAError(.passcodeNotSet))
    }
}

@MainActor
final class BiometricAuthServiceTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        NeutrinoApp.configure(.macAtlas)
        defaults = UserDefaults(suiteName: "BiometricAuthServiceTests")
        defaults.removePersistentDomain(forName: "BiometricAuthServiceTests")
    }

    func testWithoutBiometricsEnablingIsRefusedByDefault() {
        let service = BiometricAuthService(defaults: defaults, evaluator: PasscodeOnlyEvaluator())
        XCTAssertEqual(service.availability(), .notAvailable)
        service.isEnabled = true
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.lastError, .unavailable)
    }

    func testAPasscodeAloneIsEnoughWhenBiometricsArentRequired() async {
        let evaluator = PasscodeOnlyEvaluator()
        let service = BiometricAuthService(defaults: defaults, evaluator: evaluator, requiresBiometrics: false)
        XCTAssertEqual(service.availability(), .available(.none))
        service.isEnabled = true
        XCTAssertTrue(service.isEnabled)
        service.lockOnLaunch()
        XCTAssertTrue(service.isLocked)
        let unlocked = await service.unlock()
        XCTAssertTrue(unlocked)
        XCTAssertFalse(service.isLocked)

        evaluator.passcodeSet = false
        XCTAssertEqual(service.availability(), .passcodeNotSet)
    }

    func testLockLocksAtOnceOnlyWhenEnabled() {
        let service = BiometricAuthService(defaults: defaults, evaluator: PasscodeOnlyEvaluator(), requiresBiometrics: false)
        service.lock()
        XCTAssertFalse(service.isLocked, "off: nothing to lock")
        service.isEnabled = true
        service.sceneDidEnterBackground()
        service.lock()
        XCTAssertTrue(service.isLocked)
        XCTAssertNil(service.lastBackgroundedAt)
    }
}
