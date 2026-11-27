import Foundation
import SwiftUI
import UIKit
import UserNotifications

@_silgen_name("clearsign_setup_pair") private func setupPair(_ path: UnsafePointer<CChar>) -> Bool
@_silgen_name("clearsign_setup_verify") private func setupVerify(_ path: UnsafePointer<CChar>) -> Bool
@_silgen_name("clearsign_setup_auth") private func setupAuth(_ path: UnsafePointer<CChar>, _ email: UnsafePointer<CChar>, _ password: UnsafePointer<CChar>, _ server: UnsafePointer<CChar>) -> Bool
@_silgen_name("clearsign_setup_poll") private func setupPoll() -> UnsafeMutablePointer<CChar>?
@_silgen_name("clearsign_setup_code") private func setupCode(_ code: UnsafePointer<CChar>) -> Bool
@_silgen_name("clearsign_setup_cancel") private func setupCancel()
@_silgen_name("clearsign_free") private func setupFree(_ ptr: UnsafeMutablePointer<CChar>)

private struct SetupSnapshot: Decodable {
    let phase: String
    let code: String?
    let kind: String?
    let challenge: Int?
    let retry: Bool?
    let port: Int32?
    let identifier: String?
    let txt: [String: String]?
}

@MainActor final class ClearSignSetup: NSObject, ObservableObject, NetServiceDelegate {
    @Published private(set) var status = "Configuración independiente · experimental"
    @Published private(set) var running = false
    @Published private(set) var paired = false
    @Published private(set) var verified = false
    @Published private(set) var pairCode: String?
    @Published private(set) var needsCode = false
    @Published private(set) var canRequestSMS = false
    static let shared = ClearSignSetup()
    @Published private(set) var notified = false
    @Published private(set) var pendingSave = false
    var authControls: AuthenticationControls {
        AuthenticationControls(verified: verified, running: running, signingRunning: ClearSign.shared.running, setupActive: ClearSign.shared.setupActive, pendingSave: pendingSave)
    }
    private var service: NetService?
    private var directory: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pollTask: Task<Void, Never>?
    private var lastPhase = ""
    private var stopping = false
    private let notificationID = "clearsign.setup.pairing-code"
    var hasSavedPairing: Bool { ClearSignVault.storedPairing() != nil }
    static let providers = ["https://new.ani.sidestore.io", "https://mac-ani.jkcoxson.com", "https://ani.iloader.app", "https://ani3.stikstore.app", "https://ani.jkcoxson.com", "https://ani2.stikstore.app", "https://win.ani.sidestore.io", ""]

    static func purgeAbandonedSetup() {
        guard let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("ClearSign-Setup", isDirectory: true))
    }
    private func prepare() throws -> URL {
        if let directory { return directory }
        let fm = FileManager.default
        let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var url = root.appendingPathComponent("ClearSign-Setup", isDirectory: true)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
        directory = url
        return url
    }
    private func removeStaging() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; paired = false; verified = false; pendingSave = false
    }
    func enablePairNotification() async {
        do { notified = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); status = notified ? "Aviso del código local autorizado." : "Aviso denegado; podés leer el código en esta pantalla." }
        catch { status = "No se pudo autorizar el aviso: " + error.localizedDescription }
    }
    func beginPair() {
        guard !pendingSave, ClearSign.shared.controls.canStartSetup(setupRunning: running) else { status="Hay una operación en curso."; return }
        do {
            removeStaging()
            ClearSign.shared.setSetupActive(true)
            let d = try prepare()
            launch(d.path.withCString { setupPair($0) }, text: "Preparando emparejamiento local…", pairing: true)
        } catch { removeStaging(); ClearSign.shared.setSetupActive(false); status = "No se pudo preparar el almacenamiento local protegido." }
    }
    func restorePairing() {
        guard !pendingSave,!running,!ClearSign.shared.running,let data=ClearSignVault.storedPairing() else { status="No hay emparejamiento guardado disponible."; return }
        do {
            removeStaging()
            ClearSign.shared.setSetupActive(true)
            let d=try prepare()
            try data.write(to:d.appendingPathComponent("pairing.plist"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            paired=true;verified=false
            verify()
        } catch { removeStaging();ClearSign.shared.setSetupActive(false);status="No se pudo recuperar el emparejamiento local." }
    }
    var canPauseForImport: Bool { !running && !pendingSave && !ClearSign.shared.running }
    func pauseForImport() -> Bool {
        guard canPauseForImport else { return false }
        if ClearSign.shared.setupActive {
            verified=false
            ClearSign.shared.setSetupActive(false)
            status="Configuración pausada para importar. El emparejamiento se conserva; podés comprobarlo nuevamente."
        }
        return true
    }
    func verify() {
        guard paired, !pendingSave, !running, !ClearSign.shared.running, let directory else { status="Primero creá un emparejamiento o finalizá la operación en curso."; return }
        ClearSign.shared.setSetupActive(true)
        verified=false
        launch(directory.path.withCString { setupVerify($0) }, text: "Comprobando con LocalDevVPN…", pairing: false)
    }
    @discardableResult
    func authenticate(email: String, password: String, server: String, consent: Bool) -> Bool {
        guard authControls.canEnterCredentials, let directory else {
            status="Falta comprobar el emparejamiento o hay una operación en curso."; return false
        }
        guard consent, AuthenticationControls.validCredentials(email: email, password: password), Self.providers.contains(server) else {
            status="Revisá la cuenta, contraseña, servidor y autorización."; return false
        }
        // The obsolete build 20/21 timestamp is deliberately not read.
        // No local cooldown or background login. Original BariStore handles the authorized foreground flow.
        let ok = authControls.submit(email: email, password: password, consent: consent) {
            directory.path.withCString { d in email.withCString { e in password.withCString { p in server.withCString { s in setupAuth(d,e,p,s) } } } }
        }
        launch(ok, text: "Autenticando con el motor original de BariStore…", pairing: false)
        return ok
    }
    @discardableResult
    func submit(_ code: String) -> Bool {
        guard running, !stopping, needsCode, AuthenticationControls.validCode(code) else { status="Ingresá seis dígitos cuando Apple solicite el código."; return false }
        guard code.withCString({ setupCode($0) }) else {
            status="El motor no aceptó el código. No se realizó un nuevo intento."; return false
        }
        needsCode=false; canRequestSMS=false; status="Verificando el código…"
        return true
    }
    func requestSMS() {
        guard running,!stopping,needsCode,canRequestSMS else { return }
        if "sms".withCString({ setupCode($0) }) {
            needsCode=false;canRequestSMS=false;status="Solicitando SMS por elección del usuario…"
        } else { status="No se aceptó la solicitud de SMS." }
    }
    func saveAuthenticatedSession() {
        guard pendingSave, !running, let directory else { return }
        if ClearSign.shared.importSession(directory, fromSetup: true) {
            ClearSign.shared.setSetupActive(false)
            removeStaging()
            status="Sesión guardada localmente. Falta comprobar una renovación manual."
        } else {
            status="Autenticación completada, pero no se guardó la sesión. "+ClearSign.shared.status+" Podés reintentar guardar sin autenticarte."
        }
    }
    private func launch(_ ok: Bool, text: String, pairing: Bool) {
        guard ok else { if pairing { removeStaging(); ClearSign.shared.setSetupActive(false) }; status = "El motor está ocupado o no pudo iniciar. No se reintentó."; return }
        running = true; stopping = false; needsCode = false; canRequestSMS=false; pairCode = nil; lastPhase = ""; status = text
        if pairing {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Emparejamiento de A19Core autorizado") { [weak self] in
                Task { @MainActor in self?.cancel() }
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.running else { return }
                self.poll()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
    func cancel() {
        guard running else { removeStaging(); ClearSign.shared.setSetupActive(false); status = "Configuración cancelada."; return }
        stopping = true; setupCancel(); stopNetwork(); status = "Cancelando…"
    }
    private func stopNetwork() {
        service?.stop(); service = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    private func finish(_ text: String) {
        stopNetwork(); running = false; pairCode = nil; needsCode = false; canRequestSMS=false; pollTask?.cancel(); pollTask = nil; status = text
    }
    private func poll() {
        guard let p = setupPoll() else { status="El motor no devolvió estado. La operación sigue pendiente; podés cancelarla."; return }; defer { setupFree(p) }
        guard let snapshot = try? JSONDecoder().decode(SetupSnapshot.self, from: Data(String(cString: p).utf8)) else { status="El estado del motor no se pudo leer. Podés cancelar la operación."; return }
        let phaseKey = snapshot.phase + ":" + String(snapshot.challenge ?? 0)
        guard phaseKey != lastPhase else { return }; lastPhase = phaseKey
        if stopping && snapshot.phase != "error" && snapshot.phase != "paired" && snapshot.phase != "verified" && snapshot.phase != "authenticated" { return }
        if stopping { removeStaging(); ClearSign.shared.setSetupActive(false); finish("Configuración cancelada. No se guardó una nueva sesión."); return }
        switch snapshot.phase {
        case "advertise":
            guard let port = snapshot.port, let id = snapshot.identifier, let txt = snapshot.txt, port > 0 else { cancel(); return }
            let s = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: id, port: port)
            s.delegate = self; s.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) })); service = s; s.publish()
        case "pairCode":
            pairCode = snapshot.code; status = "Ingresá el código en la solicitud de emparejamiento de iOS."
            if notified, let code = pairCode {
                let content = UNMutableNotificationContent(); content.title = "A19Core · emparejamiento"; content.body = "Código local: " + code
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil), withCompletionHandler: nil)
            }
        case "paired": paired = true; verified = false; finish("Emparejamiento recibido. Conectá LocalDevVPN y comprobalo.")
        case "verified":
            guard let directory else {finish("No se encontró el emparejamiento.");return}
            do {
                try ClearSignVault.savePairing(Data(contentsOf:directory.appendingPathComponent("pairing.plist")))
                verified=true;finish("Emparejamiento comprobado y guardado. Podés configurar la cuenta de firma.")
            } catch { verified=false;finish("No se pudo guardar el emparejamiento: "+error.localizedDescription) }
        case "twoFactor":
            needsCode=true;canRequestSMS=snapshot.kind=="trustedDevice"
            status=(snapshot.retry == true ? "El código anterior fue rechazado. " : "") + (snapshot.kind=="sms" ? "Apple solicita un código SMS." : "Apple solicita un código de dispositivo de confianza.")
        case "authenticating": needsCode=false;canRequestSMS=false;status="Autenticación en curso con el motor original de BariStore."
        case "authenticated":
            guard directory != nil else { ClearSign.shared.setSetupActive(false); finish("No se encontró la sesión local."); return }
            pendingSave=true
            finish("Autenticación completada. Guardando sesión…")
            saveAuthenticatedSession()
        case "error":
            let c = snapshot.code ?? "engine_unavailable"
            if !paired || c == "cancelled" { removeStaging(); ClearSign.shared.setSetupActive(false) }
            // Keep verified pairing and the currently staged identity; no automatic retry.
            finish(Self.errorMessage(c)+" ["+c+"]. No se reintentó automáticamente.")
        default: break
        }
    }
    private static func errorMessage(_ code:String)->String {
        switch code {
        case "auth_code_rejected": return "Apple rechazó el código de verificación"
        case "auth_rate_limited","auth_security_stop": return "Apple limitó la operación o requiere una acción de seguridad; no repitas el inicio de sesión"
        case "auth_credentials_or_throttled": return "Apple rechazó las credenciales o limitó la cuenta"
        case "auth_additional_verification": return "Apple requiere una verificación adicional"
        case "auth_verification_response": return "Respuesta de verificación inesperada"
        case "auth_verification_refused": return "Apple rechazó la verificación"
        case "auth_token_failed","auth_token_invalid": return "No se obtuvo un token de firma válido"
        case "auth_identity_refused","auth_anisette_unavailable": return "Identidad de autenticación no disponible o rechazada"
        case "auth_service_refused","auth_connection_failed","auth_verification_transport": return "Servicio de autenticación no disponible"
        case "auth_post_verification": return "No se completó la sesión después del código"
        case "auth_storage_failed": return "No se pudo conservar la sesión"
        case "auth_upstream_failed": return "El motor original de BariStore no completó la autenticación"
        case "auth_session_invalid": return "Apple no devolvió los datos necesarios de sesión"
        case "auth_initial_handshake": return "No se completó el inicio de sesión"
        case "auth_cancelled","cancelled": return "Operación cancelada"
        case "engine_busy": return "El motor está ocupado"
        case "vpn_or_pairing_unavailable": return "No se pudo comprobar el emparejamiento; revisá LocalDevVPN"
        case "device_mismatch": return "El emparejamiento no corresponde a este iPhone"
        case "timeout": return "La operación agotó el tiempo disponible"
        default: return "Operación detenida"
        }
    }
    func netServiceDidPublish(_ sender: NetService) { status = "Anuncio local publicado. En Ajustes, aprobá el emparejamiento en Modo de desarrollador." }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) { cancel(); status = "iOS no permitió publicar el anuncio. Revisá el permiso de red local." }
}

struct ClearSignSetupPanel: View {
    @ObservedObject private var setup = ClearSignSetup.shared
    @ObservedObject private var signing = ClearSign.shared
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var server = ClearSignSetup.providers[0]
    @State private var consent = false
    var body: some View {
        Text("Configurar ClearSign sin BariStore").font(.headline)
        Text(setup.status).font(.footnote)
        Button("Permitir aviso del código local") { Task { await setup.enablePairNotification() } }.disabled(setup.running)
        Button("Crear emparejamiento propio") { setup.beginPair() }.disabled(setup.pendingSave || !signing.controls.canStartSetup(setupRunning: setup.running))
        if signing.automatic { Text("La renovación se pausa mientras configurás el emparejamiento.").font(.caption).foregroundStyle(.secondary) }
        if let c = setup.pairCode { Text(c).font(.title.monospacedDigit()).privacySensitive() }
        Button("Comprobar emparejamiento") { setup.verify() }.disabled(!setup.paired || setup.pendingSave || setup.running || signing.running)
        if !setup.paired {
            if setup.hasSavedPairing { Button("Recuperar emparejamiento guardado") { setup.restorePairing() }.disabled(setup.running || signing.running) }
            else { Text("Creá primero un emparejamiento propio.").font(.caption).foregroundStyle(.secondary) }
        }
        if setup.verified && !setup.pendingSave {
            Text("No inicies sesión si Apple limitó tu cuenta. El método no es una API pública de autenticación de Apple. No guardamos la contraseña ni cambiamos certificados.").font(.caption)
            Picker("Servidor Anisette", selection: $server) { ForEach(ClearSignSetup.providers, id: \.self) { Text($0.isEmpty ? "Automático (BariStore)" : $0).tag($0) } }.disabled(setup.running)
            Text("El motor original puede probar las dos identidades del servidor seleccionado. Automático también puede probar otros servidores. Cada código requiere tu intervención. No se inicia sesión en segundo plano.").font(.caption)
            TextField("Cuenta Apple", text: $email).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress).disabled(setup.running)
            SecureField("Contraseña (solo en este iPhone)", text: $password).disabled(setup.running)
            Toggle("Autorizo el flujo de BariStore en la ruta elegida", isOn: $consent).disabled(setup.running)
            Button("Autenticar una vez") {
                if setup.authenticate(email: email, password: password, server: server, consent: consent) {
                    // The engine has copied the input; clear the secret only after acceptance.
                    password = ""; consent = false
                }
            }.disabled(!consent || !AuthenticationControls.validCredentials(email: email, password: password) || !setup.authControls.canEnterCredentials)
            if setup.running {
                ProgressView(setup.status).font(.footnote)
            } else {
                Text(setup.status).font(.footnote)
            }
        }
        if setup.running && !setup.verified { ProgressView(setup.status).font(.footnote) }
        if setup.needsCode {
            SecureField("Código de seis dígitos", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
            Button("Validar código") { if setup.submit(code) { code = "" } }.disabled(!AuthenticationControls.validCode(code))
            if setup.canRequestSMS { Button("Solicitar código por SMS") { setup.requestSMS();code="" } }
        }
        if setup.pendingSave { Button("Guardar sesión nuevamente") { setup.saveAuthenticatedSession() }.disabled(setup.running || signing.running) }
        Button("Cancelar configuración") { setup.cancel(); email = ""; password = ""; code = ""; consent = false }.disabled(!setup.running && !setup.paired && !signing.setupActive)
    }
}
