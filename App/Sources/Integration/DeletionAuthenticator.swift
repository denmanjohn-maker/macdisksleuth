import Foundation
import LocalAuthentication

/// The gate in front of every batch deletion: Touch ID or Apple Watch where
/// the Mac has them, the login password otherwise. Nothing is moved unless
/// this says yes. `import LocalAuthentication` links the framework; macOS
/// needs no Info.plist usage string for it.
@MainActor
enum DeletionAuthenticator {
    enum Outcome: Sendable {
        case success
        /// A short, user-facing explanation; the caller shows it and keeps the selection.
        case failure(String)
    }

    /// `reason` completes the sentence "MacDiskSleuth is trying to …".
    static func authenticate(reason: String) async -> Outcome {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password…"
        context.localizedCancelTitle = "Cancel"

        var availability: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availability) else {
            return .failure(describe(availability))
        }
        do {
            let granted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return granted ? .success : .failure("Authentication failed. Nothing was moved.")
        } catch {
            return .failure(describe(error as NSError))
        }
    }

    private static func describe(_ error: NSError?) -> String {
        guard let error else { return "Authentication isn't available on this Mac. Nothing was moved." }
        guard error.domain == LAErrorDomain, let code = LAError.Code(rawValue: error.code) else {
            return error.localizedDescription
        }
        switch code {
        case .userCancel:
            return "Authentication was cancelled. Nothing was moved."
        case .userFallback:
            return "Password entry was cancelled. Nothing was moved."
        case .authenticationFailed:
            return "Authentication failed. Nothing was moved."
        case .biometryNotAvailable, .biometryNotEnrolled:
            return "Touch ID isn't available here; use your login password instead."
        case .biometryLockout:
            return "Touch ID is locked after too many attempts; use your login password instead."
        case .passcodeNotSet:
            return "This Mac has no login password, so deletions can't be authorised. Set one in System Settings › Users & Groups."
        case .appCancel, .systemCancel, .invalidContext, .notInteractive:
            return "Authentication was interrupted. Try again."
        default:
            return error.localizedDescription
        }
    }
}
