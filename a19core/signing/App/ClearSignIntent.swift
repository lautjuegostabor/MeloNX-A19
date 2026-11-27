import AppIntents
import Foundation

// Host-only: signing credentials and native engine are never linked into the JIT extension.
@available(iOS 27.0, *)
struct A19SigningPreventiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Comprobar renovación A19Core"
    static var description = IntentDescription("Comprueba la vigencia y renueva perfiles si corresponde. Requiere sesión y renovación preventiva activada.")
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let message = await ClearSign.shared.preventiveCheck()
        return .result(value: message)
    }
}
