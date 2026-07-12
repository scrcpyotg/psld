import Foundation
import Combine
import LocalAuthentication

final class BiometricLockController: ObservableObject {
    @Published private(set) var isUnlocked = true
    @Published private(set) var isBiometricsAvailable = false
    @Published var lastError: String?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            isUnlocked = !newValue
            if newValue {
                unlock()
            }
        }
    }

    private let enabledKey = "psl.local.biometric.lock.enabled"

    init() {
        refreshAvailability()
        isUnlocked = !isEnabled
    }

    func refreshAvailability() {
        let context = LAContext()
        var error: NSError?
        isBiometricsAvailable = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
    }

    func lock() {
        guard isEnabled else { return }
        isUnlocked = false
    }

    func unlock() {
        guard isEnabled else {
            isUnlocked = true
            return
        }

        let context = LAContext()
        context.localizedCancelTitle = "Отмена"
        var error: NSError?

        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &error
        ) else {
            lastError = "На устройстве недоступна системная аутентификация."
            isUnlocked = false
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Открыть личный кабинет и историю сканов"
        ) { [weak self] success, evaluationError in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isUnlocked = success
                self.lastError = success ? nil : (evaluationError?.localizedDescription ?? "Не удалось разблокировать приложение.")
            }
        }
    }
}
