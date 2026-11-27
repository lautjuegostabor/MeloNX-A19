import Foundation
import SwiftUI
import Combine
import Security
import BackgroundTasks
import UserNotifications
import UniformTypeIdentifiers
import CryptoKit
import LocalAuthentication

@_silgen_name("clearsign_cancel_refresh")
private func nativeCancelRefresh()
@_silgen_name("clearsign_refresh")
private func nativeRefresh(_ directory: UnsafePointer<CChar>,_ data: UnsafePointer<UInt8>,_ count: Int) -> UnsafeMutablePointer<CChar>?
@_silgen_name("clearsign_free")
private func nativeFree(_ pointer: UnsafeMutablePointer<CChar>)

private struct EmbeddedProfile {
    let bundleID: String
    let uuid: String
    let team: String
    let signingCertificateSHA256: String?
    let expires: Date
    let bytes: Data
    init?(_ bundle: Bundle) {
        guard let id=bundle.bundleIdentifier,
              let url=bundle.url(forResource:"embedded",withExtension:"mobileprovision"),
              let data=try? Data(contentsOf:url),data.count <= 1_000_000,
              let start=data.range(of:Data("<plist".utf8)),let end=data.range(of:Data("</plist>".utf8),in:start.lowerBound..<data.endIndex),
              let p=try? PropertyListSerialization.propertyList(from:data.subdata(in:start.lowerBound..<end.upperBound),format:nil) as? [String:Any],
              let uuid=p["UUID"] as? String,let team=(p["TeamIdentifier"] as? [String])?.first,let exp=p["ExpirationDate"] as? Date else {return nil}
        bundleID=id;self.uuid=uuid;self.team=team;bytes=data
        let fingerprint=bundle.object(forInfoDictionaryKey:"ClearSignCertificateSHA256") as? String
        let certs=p["DeveloperCertificates"] as? [Data] ?? []
        let matches=certs.filter{cert in SHA256.hash(data:cert).map{String(format:"%02x",$0)}.joined()==fingerprint}
        if let fingerprint,matches.count==1,
           let notAfter=bundle.object(forInfoDictionaryKey:"ClearSignCertificateExpires") as? NSNumber,
           notAfter.doubleValue.isFinite,notAfter.doubleValue>0 {
            signingCertificateSHA256=fingerprint
            expires=min(exp,Date(timeIntervalSince1970:notAfter.doubleValue))
        }else{
            signingCertificateSHA256=nil;expires=exp
        }
    }
    static func installed() -> [EmbeddedProfile] {
        guard let main=EmbeddedProfile(.main),let dir=Bundle.main.builtInPlugInsURL,
              let urls=try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil),
              urls.filter({$0.pathExtension=="appex"}).count==1,
              let extURL=urls.first(where:{$0.lastPathComponent=="MeloNXJITHelper.appex"}),
              let ext=Bundle(url:extURL).flatMap(EmbeddedProfile.init) else{return []}
        guard A19SigningPolicy.validPair(mainID:main.bundleID, helperID:ext.bundleID, mainTeam:main.team, helperTeam:ext.team) else{return []}
        return [main,ext]
    }
}

private struct ClearSignError: LocalizedError {
    let message:String
    var errorDescription:String? {message}
}
// Sensitive exported BariStore session and pairing material never leaves device.
// Only Keychain retains it between runs. No Apple password or signing private key.
enum ClearSignVault {
    static let service="com.a19core.clearsign"
    static let account="baristore-session-v1"
    static var query:[String:Any] {[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]}
    static func load()->[String:Data]? {
        var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var out:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&out)==errSecSuccess,let d=out as? Data else{return nil}
        guard let files = try? JSONDecoder().decode([String:Data].self,from:d) else { return nil }
        return try? validateSession(files)
    }
    static func sessionDefinitelyMissing() -> Bool {
        var q=query; q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var out:CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &out)
        if result == errSecItemNotFound { return true }
        guard result == errSecSuccess else { return false } // locked/inaccessible is not absence
        guard let d=out as? Data, let files=try? JSONDecoder().decode([String:Data].self,from:d) else { return true }
        return (try? validateSession(files)) == nil
    }
    // Pairing is independent of Apple authentication and survives failed login.
    private static var pairingQuery:[String:Any] {
        var q=query; q[kSecAttrAccount as String]="clearsign-pairing-v1"; return q
    }
    static func storedPairing() -> Data? {
        var q=pairingQuery; q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var out:CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary,&out)==errSecSuccess,let data=out as? Data,!data.isEmpty,data.count<=256_000{return data}
        return nil
    }
    static func savePairing(_ data:Data) throws {
        guard !data.isEmpty,data.count<=256_000 else{throw ClearSignError(message:"Emparejamiento inválido.")}
        let attrs:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result=SecItemUpdate(pairingQuery as CFDictionary,attrs as CFDictionary)
        if result==errSecItemNotFound {
            var q=pairingQuery; for (k,val) in attrs{q[k]=val}
            guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else{throw ClearSignError(message:"No se pudo guardar el emparejamiento.")}
        }else if result != errSecSuccess {throw ClearSignError(message:"No se pudo guardar el emparejamiento.")}
    }
    static func save(_ entries:[String:Data]) throws {
        let d=try JSONEncoder().encode(entries)
        var q=query;q[kSecValueData as String]=d;q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:d,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        if status==errSecItemNotFound {
            guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else{throw ClearSignError(message:"No se pudo guardar la sesión en Keychain.")}
        } else if status != errSecSuccess {throw ClearSignError(message:"No se pudo actualizar Keychain.")}
    }
    static func erase() throws {
        let result=SecItemDelete(query as CFDictionary)
        guard result==errSecSuccess || result==errSecItemNotFound else { throw ClearSignError(message:"No se pudo eliminar la sesión local de firma.") }
    }
    static func allowed(_ name:String)->Bool {
        if ["account.plist","pairing.plist","anisette-server","host-uuid","device-port"].contains(name){return true}
        return name.hasPrefix("anisette-") && name.hasSuffix(".plist") && !name.contains("/") && !name.contains("..") && name.count<200
    }
    static func readFolder(_ url:URL) throws -> [String:Data] {
        let scoped=url.startAccessingSecurityScopedResource()
        defer {if scoped{url.stopAccessingSecurityScopedResource()}}
        let files=try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        var result:[String:Data]=[:];var size=0
        for item in files where allowed(item.lastPathComponent) {
            let v=try item.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard v.isRegularFile==true,v.isSymbolicLink != true,let n=v.fileSize,n<=256_000 else{continue}
            size += n
            guard size<=1_000_000 else{throw ClearSignError(message:"Exportación demasiado grande.")}
            result[item.lastPathComponent]=try Data(contentsOf:item)
        }
        return try validateSession(result)
    }
    static func validateSession(_ result:[String:Data]) throws -> [String:Data] {
        guard result.count<=64,result.allSatisfy({allowed($0.key) && $0.value.count<=256_000}),result.values.reduce(0,{$0+$1.count})<=1_000_000 else{throw ClearSignError(message:"Respaldo de sesión inválido.")}
        guard result["account.plist"] != nil,result["pairing.plist"] != nil,
              let route=result["anisette-server"].flatMap({String(data:$0,encoding:.utf8)}),
              route.hasPrefix("https://"),result.keys.contains(where:{$0.hasPrefix("anisette-") && $0.hasSuffix(".plist")})
        else{throw ClearSignError(message:"Faltan sesión, identidad de anisette o emparejamiento.")}
        return result
    }
}
private struct SignRequest:Encodable {
    struct Item:Encodable {let bundleID:String;let profile:String;let signingCertificateSHA256:String?}
    let bundles:[Item]
    let previousExpiry:UInt64
}
private struct SignResult:Decodable {
    let ok:Bool
    let expiry:UInt64?
    let code:String?
    let installedID:String?
    let profilesVerified:Bool?
}
private struct SignReceipt:Codable {
    let installation:String
    let expiry:Date
    let at:Date
}

@MainActor final class ClearSign:ObservableObject {
    static let shared=ClearSign()
    static var taskID: String? {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        let matches = ids.filter { $0.hasSuffix(".clearsign") }
        return matches.count == 1 ? matches.first : nil
    }
    @Published private(set) var configured=false
    @Published private(set) var status="Sin configurar"
    @Published private(set) var running=false
    @Published private(set) var setupActive=false
    @Published private(set) var expiry:Date?
    @Published private(set) var alertStatus="Sin consultar permisos de avisos."
    var controls: SigningControls { SigningControls(configured: configured, automatic: automatic, running: running, setupActive: setupActive, validExpiry: expiry.map { $0 > Date() } ?? false) }
    @Published var automatic:Bool {
        didSet {UserDefaults.standard.set(automatic,forKey:"clearsign.auto");schedule();Task{await notifications()}}
    }
    private var registered=false
    private let receiptKey="clearsign.receipt.readback.v2"
    private let attemptKey="clearsign.attempt"
    private let alertIDs=["clearsign.warning48","clearsign.warning24"]
    private init(){automatic=UserDefaults.standard.bool(forKey:"clearsign.auto");update()}
    private func installation(_ profiles:[EmbeddedProfile])->String {
        let bytes=Data(profiles.map{$0.bundleID+":"+$0.uuid}.joined(separator:"|").utf8)
        return SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    }
    private func currentExpiry(_ profiles:[EmbeddedProfile])->Date? {
        guard let embedded=profiles.map(\.expires).min(),profiles.count==2 else{return nil}
        if let d=UserDefaults.standard.data(forKey:receiptKey),let r=try? JSONDecoder().decode(SignReceipt.self,from:d),
           r.installation==installation(profiles){return max(embedded,r.expiry)}
        return embedded
    }
    func update(){
        configured=ClearSignVault.load() != nil
        expiry=currentExpiry(EmbeddedProfile.installed())
        if !configured {
            if automatic && !SigningControls.normalizedAutomatic(automatic, sessionDefinitelyMissing: ClearSignVault.sessionDefinitelyMissing()) { automatic=false }
            status="No hay sesión de firma disponible. Importá un respaldo o creá un emparejamiento propio. La renovación no puede ejecutarse sin sesión."
        }
        else if expiry==nil{status="No se pudieron leer los perfiles de la app y el auxiliar JIT."}
        else if status=="Sin configurar" || status.hasPrefix("Configurá") || status.hasPrefix("No hay sesión"){status="Sesión importada. Pendiente de renovación comprobada."}
    }
    func register(){
        guard !registered else{return}
        guard let taskID = Self.taskID else { status = "Falta el identificador efectivo de renovación."; return }
        if let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("ClearSign-Transient", isDirectory: true))
        }
        registered=BGTaskScheduler.shared.register(forTaskWithIdentifier:taskID,using:nil){task in
            guard let task=task as? BGProcessingTask else{task.setTaskCompleted(success:false);return}
            Task{@MainActor in Self.shared.handle(task)}
        }
        if !registered{status="iOS no registró la tarea de renovación automática."}
    }
    func setSetupActive(_ active: Bool) {
        setupActive = active
        schedule()
    }
    func schedule(){
        guard registered, let taskID = Self.taskID else{return}
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:taskID)
        guard !setupActive,automatic,configured,let expiry,expiry>Date() else{return}
        let earliest=max(Date().addingTimeInterval(60),expiry.addingTimeInterval(-5*86400))
        let last=Date(timeIntervalSince1970:UserDefaults.standard.double(forKey:attemptKey))
        let req=BGProcessingTaskRequest(identifier:taskID)
        req.earliestBeginDate=max(earliest,last.addingTimeInterval(6*3600))
        req.requiresNetworkConnectivity=true
        req.requiresExternalPower=false
        do{try BGTaskScheduler.shared.submit(req)}catch{status="iOS no aceptó programar la renovación. "+error.localizedDescription}
    }
    @discardableResult func importSession(_ url:URL, fromSetup: Bool = false) -> Bool {
        guard !running, !setupActive || fromSetup else{return false}
        do{
            let data=try ClearSignVault.readFolder(url)
            try ClearSignVault.save(data)
            configured=true;status="Sesión importada. Probá renovar ahora."
            update();schedule()
            Task{await notifications()}
            return true
        }catch{status=error.localizedDescription;return false}
    }
    func importEncryptedSession(_ bytes:Data,secret:String) throws {
        guard !running,!setupActive else{throw ClearSignError(message:"ClearSign está ocupado.")}
        let files=try ClearSignVault.validateSession(ClearRecoveryExport.decryptSession(bytes:bytes,secret:secret))
        try ClearSignVault.save(files)
        configured=true
        status="Sesión importada. Probá renovar ahora; todavía no se confirmó la firma."
        update();schedule();Task{await notifications()}
    }
    func recoveryExport() throws -> (ClearRecoveryDocument, String) {
        guard !running, !setupActive, let files=ClearSignVault.load() else { throw ClearSignError(message:"No hay sesión disponible.") }
        let profiles=EmbeddedProfile.installed()
        guard profiles.count==2,let until=currentExpiry(profiles) else { throw ClearSignError(message:"No hay dos perfiles válidos.") }
        let request=SignRequest(bundles:profiles.map{.init(bundleID:$0.bundleID,profile:$0.bytes.base64EncodedString(),signingCertificateSHA256:$0.signingCertificateSHA256)}, previousExpiry:UInt64(max(0,until.timeIntervalSince1970)))
        return try ClearRecoveryExport.encrypt(request:JSONEncoder().encode(request),files:files)
    }
    func forget(){
        guard !running,!setupActive else{return}
        do {
            try ClearSignVault.erase()
            automatic=false;configured=false
            status="Sesión eliminada de Keychain. La aplicación sigue instalada."
            Task { await notifications() }
        } catch { status=error.localizedDescription }
    }
    func enableAlerts() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge])
            alertStatus = granted ? "Avisos autorizados. Se programarán antes del vencimiento." : "Avisos denegados. Habilitalos en Ajustes > Notificaciones."
            await notifications()
        } catch { alertStatus="No se pudo habilitar avisos: "+error.localizedDescription }
    }
    func refreshAlerts() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: alertStatus="Avisos autorizados."
        case .denied: alertStatus="Avisos denegados. Revisá Ajustes > Notificaciones."
        case .notDetermined: alertStatus="Avisos aún sin autorización."
        @unknown default: alertStatus="Estado de avisos desconocido."
        }
        await notifications()
    }
    private func notifications() async {
        let center=UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers:alertIDs)
        let settings=await center.notificationSettings()
        guard [.authorized,.provisional,.ephemeral].contains(settings.authorizationStatus),let expiry,expiry>Date() else{return}
        for (id,days) in zip(alertIDs,[2.0,1.0]){
            let remaining=expiry.addingTimeInterval(-days*86400).timeIntervalSinceNow
            let c=UNMutableNotificationContent()
            c.title="A19Core: revisá la firma"
            c.body="No hay confirmación de una renovación posterior. Abrí A19Core o BariStore antes del vencimiento."
            c.sound = .default
            if remaining>0 {
                let trigger=UNTimeIntervalNotificationTrigger(timeInterval:max(1,remaining),repeats:false)
                do { try await center.add(UNNotificationRequest(identifier:id,content:c,trigger:trigger)) }
                catch { alertStatus="No se pudo programar un aviso: "+error.localizedDescription }
            }
        }
    }
    // Shared entry point for foreground and Shortcuts, with same throttle as BG task.
    func preventiveCheck() async -> String {
        update()
        guard automatic else{return "Renovación preventiva desactivada."}
        guard configured else{return "No hay sesión válida. No se inició sesión en Apple."}
        guard !running,!setupActive else{return "ClearSign tiene otra operación en curso."}
        guard let expiry,expiry>Date() else{return "No hay vigencia comprobable."}
        guard expiry.timeIntervalSinceNow<=5*86400 else{return "Firma vigente. No corresponde renovar todavía."}
        let last=UserDefaults.standard.double(forKey:attemptKey)
        guard Date().timeIntervalSince1970-last>=6*3600 else{return "Ya hubo un intento reciente. No se repitió."}
        let ok=await renew(automaticRun:true)
        return ok ? status : "No se confirmó renovación. "+status
    }
    private func handle(_ task:BGProcessingTask){
        let work=Task{@MainActor in await renew(automaticRun:true)}
        task.expirationHandler={work.cancel();nativeCancelRefresh()}
        Task{@MainActor in
            let success=await work.value
            task.setTaskCompleted(success:success)
            schedule()
        }
    }
    func renew(automaticRun:Bool=false) async -> Bool {
        guard !running,!setupActive else{return false}
        guard A19SigningPolicy.canRenewWhileIdle(engineActive:RyujinxController.shared.isEngineActive,gameRunning:RyujinxController.shared.isRunning.isRunning()) else { status="Hay un juego en ejecución. No se inició la renovación."; return false }
        guard let data=ClearSignVault.load() else{update();return false}
        let profiles=EmbeddedProfile.installed()
        guard profiles.count==2,let until=currentExpiry(profiles) else{status="No hay perfiles válidos de A19Core y su auxiliar JIT.";return false}
        guard until>Date() else{status="Firma vencida: recuperá la instalación con BariStore.";return false}
        if automaticRun {
            guard automatic,until.timeIntervalSinceNow<=5*86400 else{return true}
            let last=UserDefaults.standard.double(forKey:attemptKey)
            guard Date().timeIntervalSince1970-last>=6*3600 else{return false}
        }
        running=true;status="Solicitando perfiles de A19Core y del auxiliar JIT…"
        UserDefaults.standard.set(Date().timeIntervalSince1970,forKey:attemptKey)
        // Schedule the next attempt before network I/O, even if iOS terminates this task.
        schedule()
        defer{running=false;schedule();Task{await notifications()}}
        let request=SignRequest(bundles:profiles.map{.init(bundleID:$0.bundleID,profile:$0.bytes.base64EncodedString(),signingCertificateSHA256:$0.signingCertificateSHA256)},
                                previousExpiry:UInt64(max(0,until.timeIntervalSince1970)))
        guard let encoded=try? JSONEncoder().encode(request) else{return false}
        do{
            try Task.checkCancellation()
            let response=try await Task.detached(priority:.utility){
                try Self.runNative(data:data,request:encoded)
            }.value
            try Task.checkCancellation()
            // Preserve the prior session on failure.
            guard response.result.ok,let e=response.result.expiry else{
                status="Renovación no confirmada: "+Self.explanation(response.result.code)
                return false
            }
            try ClearSignVault.save(response.files)
            let new=Date(timeIntervalSince1970:Double(e))
            guard new>until else{status="El vencimiento no se extendió.";return false}
            let receipt=SignReceipt(installation:installation(profiles),expiry:new,at:Date())
            UserDefaults.standard.set(try JSONEncoder().encode(receipt),forKey:receiptKey)
            expiry=new;status="Ambos perfiles nuevos comprobados en el dispositivo. Vigencia de ejecución aún sujeta a iOS."
            return true
        }catch{status="Renovación no confirmada: "+error.localizedDescription;return false}
    }
    nonisolated private static func runNative(data:[String:Data],request:Data) throws -> (result:SignResult,files:[String:Data]){
        let fm=FileManager.default
        let root=try fm.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        var dir=root.appendingPathComponent("ClearSign-Transient",isDirectory:true)
        // Only a single native invocation is permitted by the coordinator.
        try? fm.removeItem(at:dir)
        try fm.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication,.posixPermissions:0o700])
        var rv=URLResourceValues();rv.isExcludedFromBackup=true;try dir.setResourceValues(rv)
        defer{try? fm.removeItem(at:dir)}
        for (name,bytes) in data where ClearSignVault.allowed(name){
            let target=dir.appendingPathComponent(name)
            try bytes.write(to:target,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
        }
        let pointer:UnsafeMutablePointer<CChar>?=dir.path.withCString{path in
            request.withUnsafeBytes{raw in
                guard let p=raw.bindMemory(to:UInt8.self).baseAddress else{return nil}
                return nativeRefresh(path,p,request.count)
            }
        }
        guard let pointer else{throw ClearSignError(message:"El motor no respondió.")}
        defer{nativeFree(pointer)}
        let response=try JSONDecoder().decode(SignResult.self,from:Data(String(cString:pointer).utf8))
        let updated=try ClearSignVault.readFolder(dir)
        return (response,updated)
    }
    private static func explanation(_ code:String?)->String{
        switch code{
        case "renewal_identity_missing","renewal_identity_rejected":return "identidad Anisette no disponible o rechazada; sesión original conservada."
        case "session_unavailable","session_route_invalid":return "sesión de Apple no disponible. Requiere configuración local explícita."
        case "vpn_or_pairing_unavailable","pairing_missing":return "LocalDevVPN o emparejamiento no disponible."
        case "certificate_changed","entitlements_changed","profile_identity_mismatch","device_mismatch":return "el perfil no coincide con la firma instalada; no se instaló."
        case "profile_not_extended":return "Apple todavía no extendió el vencimiento. Se conserva la vigencia anterior; el intento automático se reprogramará."
        case "signing_certificate_expires":return "el certificado de firma limita el vencimiento. Renovar perfiles no puede prolongarlo; requiere firma nueva."
        case "refresh_cancelled":return "iOS interrumpió la tarea; no se confirmó un nuevo vencimiento."
        case "profile_readback_partial":return "renovación parcial: solo uno de los dos perfiles nuevos está en el dispositivo."
        case "profile_readback_missing":return "ninguno de los dos perfiles nuevos se encontró en el dispositivo."
        case "profile_readback_unavailable","profile_readback_refused","profile_readback_invalid":return "no se pudo comprobar la lista de perfiles del dispositivo."
        case "device_install_uncertain","device_install_unconfirmed","device_install_failed":return "instalación incierta; no se registró un nuevo vencimiento."
        case "portal:team_not_authorized":return "la cuenta de ClearSign no pertenece al equipo que firmó esta copia. La cuenta debe coincidir con el equipo de esta instalación."
        case "update_newer_build_required":return "el IPA debe tener un build superior al instalado."
        case "update_installed_app_missing":return "no se encontró la instalación original; no se reemplazó ninguna app."
        case "bootstrap_same_team_use_renew":return "esta cuenta ya pertenece al equipo de la instalación. Usá Renovar ahora."
        case "bootstrap_select_single_team":return "la cuenta no tiene un único equipo seleccionable. No se solicitó certificado."
        case "bootstrap_already_installed":return "ya existe una copia con esta cuenta. Abrila; no se reemplazó."
        case "bootstrap_original_ipa_required","bootstrap_same_version_required":return "seleccioná el IPA original sin firmar de esta misma versión."
        case "portal:certificate:apple_code=7460":return "Apple no permite otro certificado. No se revocó ninguno."
        case "timeout","bootstrap_timeout":return "tiempo de espera agotado; comprobá si aparece la copia nueva antes de repetir."
        default:return code ?? "error sin detalle."
        }
    }
}

@available(iOS 16.0, *)
struct SigningPanel:View {
    @ObservedObject private var signing=ClearSign.shared
    @ObservedObject private var setup=ClearSignSetup.shared
    @State private var confirmErase=false
    @State private var importStatus=""
    var body:some View{
        Text("ClearSign · experimental").font(.headline)
        if let expiry=signing.expiry {
            LabeledContent("Vencimiento de perfiles",value:expiry.formatted(date:.abbreviated,time:.shortened))
        }else{Text("Vencimiento no disponible.")}
        Text(signing.status).font(.footnote)
        Toggle("Renovación preventiva",isOn:$signing.automatic).disabled(!signing.controls.canToggleAutomatic)
        if !signing.configured { Text("Primero configurá o importá una sesión de firma.").font(.caption).foregroundStyle(.secondary) }
        else if signing.expiry.map({ $0 <= Date() }) ?? true { Text("No hay una vigencia comprobable. Revisá la instalación en BariStore.").font(.caption).foregroundStyle(.secondary) }
        if signing.running || signing.setupActive { Text("Hay una operación de firma o configuración en curso.").font(.caption).foregroundStyle(.secondary) }
        Button("Migrar sesión local existente (opcional)"){
            guard setup.pauseForImport() else { importStatus="Finalizá la operación en curso.";return }
            SigningFilePicker.shared.pick(types:[.folder]) { url in
                guard let url else {importStatus="Selección cancelada.";return}
                importStatus=signing.importSession(url) ? "Sesión importada. Probá renovar ahora." : signing.status
            }
        }.disabled(!setup.canPauseForImport)
        if !setup.canPauseForImport { Text("Terminá o cancelá la operación actual para importar.").font(.caption).foregroundStyle(.secondary) }
        if !importStatus.isEmpty { Text(importStatus).font(.footnote) }
        Button("Renovar ahora"){Task{_ = await signing.renew()}}.disabled(!signing.controls.canRenew)
        A19SessionImportPanel()
        Button("Habilitar avisos de vencimiento"){Task{await signing.enableAlerts()}}
        Text(signing.alertStatus).font(.caption).foregroundStyle(.secondary)
        Button("Eliminar sesión de firma",role:.destructive){confirmErase=true}.disabled(!signing.controls.canManageSession)
            .confirmationDialog("¿Eliminar la sesión local de firma?",isPresented:$confirmErase,titleVisibility:.visible){
                Button("Eliminar sesión",role:.destructive){signing.forget()}
                Button("Cancelar",role:.cancel){}
            }message:{Text("Se desactiva la renovación preventiva. No se elimina la app ni se revocan certificados.")}
        Text("Requiere LocalDevVPN y sesión válida. iOS decide cuándo ejecuta tareas en segundo plano. Si vence, recuperá con BariStore. No se reemplaza el ejecutable, no se modifican partidas y no se guarda la contraseña.")
            .font(.caption).foregroundStyle(.secondary)

    }
}

@available(iOS 16.0, *)
struct A19SessionImportPanel: View {
    @ObservedObject private var signing=ClearSign.shared
    @ObservedObject private var setup=ClearSignSetup.shared
    @State private var backup:Data?
    @State private var secret=""
    @State private var message=""
    var body:some View {
        Button("Importar respaldo cifrado de ClearWidget o A19Core") {
            guard setup.pauseForImport() else {message="Finalizá la operación actual.";return}
            SigningFilePicker.shared.pick(types:[.data]) { url in
                guard let url else {message="Selección cancelada.";return}
                let scoped=url.startAccessingSecurityScopedResource()
                defer{if scoped{url.stopAccessingSecurityScopedResource()}}
                do {
                    let v=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
                    guard v.isRegularFile==true,let count=v.fileSize,count>0,count<=4*1024*1024 else{throw CocoaError(.fileReadTooLarge)}
                    let data=try Data(contentsOf:url)
                    guard data.count<=4*1024*1024,data.starts(with:Data("CLEARRECOVERY1".utf8)) else{throw CocoaError(.fileReadCorruptFile)}
                    backup=data;secret="";message="Respaldo seleccionado. Ingresá su clave."
                }catch{backup=nil;secret="";message="No se pudo leer un respaldo cifrado compatible."}
            }
        }.disabled(!setup.canPauseForImport)
        if backup != nil {
            SecureField("Clave del respaldo",text:$secret).privacySensitive()
            Button("Importar sesión") {
                guard let backup else{return}
                defer{secret=""}
                do {
                    try signing.importEncryptedSession(backup,secret:secret.trimmingCharacters(in:.whitespacesAndNewlines))
                    self.backup=nil
                    message="Sesión importada. Probá renovar; la cuenta debe pertenecer al equipo que firmó A19Core."
                }catch{message="No se pudo importar el respaldo; no se reemplazó la sesión."}
            }.disabled(secret.isEmpty || !signing.controls.canImport)
            Button("Descartar respaldo seleccionado"){backup=nil;secret="";message=""}
        }
        if !message.isEmpty{Text(message).font(.footnote)}
    }
}

@available(iOS 26.0, *)
struct A19SigningScreen:View {
    @StateObject private var picker=SigningFilePicker.shared
    @ObservedObject private var signing=ClearSign.shared
    var body:some View {
        Form {
            Section("Renovación de firma") { SigningPanel() }
            Section("Configuración independiente") { ClearSignSetupPanel() }
            Section("Respaldo local") { ClearRecoveryExportPanel() }
        }.navigationTitle("Firma de A19Core")
            .sheet(item:$picker.request,onDismiss:{picker.dismissed()}) { request in
                SigningDocumentPicker(types:request.types){picker.finish($0)}
            }
            .onAppear {signing.update();signing.schedule();Task{await signing.refreshAlerts()}}
    }
}
