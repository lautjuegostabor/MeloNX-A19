import Foundation
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import LocalAuthentication

struct ClearRecoveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}

struct ClearRecoveryExport {
    private struct Payload: Codable { let version: Int; let request: Data; let files: [String:Data] }
    static func decryptSession(bytes:Data,secret:String)throws->[String:Data] {
        let header=Data("CLEARRECOVERY1".utf8)
        guard bytes.count<=4*1024*1024,bytes.starts(with:header),
              let key=Data(base64Encoded:secret),key.count==32 else{throw CocoaError(.fileReadCorruptFile)}
        let combined=bytes.dropFirst(header.count)
        guard combined.count>=28 else{throw CocoaError(.fileReadCorruptFile)}
        let box=try AES.GCM.SealedBox(combined:Data(combined))
        let plain=try AES.GCM.open(box,using:SymmetricKey(data:key),authenticating:header)
        let payload=try JSONDecoder().decode(Payload.self,from:plain)
        guard payload.version==1 else{throw CocoaError(.fileReadCorruptFile)}
        return payload.files
    }
    static func encrypt(request: Data, files: [String:Data]) throws -> (ClearRecoveryDocument, String) {
        let data = try JSONEncoder().encode(Payload(version: 1, request: request, files: files))
        let key = SymmetricKey(size: .bits256)
        let header = Data("CLEARRECOVERY1".utf8)
        let box = try AES.GCM.seal(data, using: key, authenticating: header)
        guard let combined = box.combined else { throw CocoaError(.fileWriteUnknown) }
        let secret = key.withUnsafeBytes { Data($0).base64EncodedString() }
        return (ClearRecoveryDocument(bytes: header + combined), secret)
    }
}

struct ClearRecoveryExportPanel: View {
    @ObservedObject private var signing = ClearSign.shared
    @State private var document: ClearRecoveryDocument?
    @State private var secret = ""
    @State private var exporting = false
    @State private var status = ""
    @State private var consent = false
    var body: some View {
        Text("Respaldo independiente de ClearSign · experimental").font(.headline)
        Text("Crea una copia cifrada de la sesión y de los perfiles de esta instalación. Conservá el archivo y su clave separados, solo en almacenamiento local. No los envíes ni los subas a servicios en la nube. No incluye contraseña ni clave privada de firma.").font(.caption)
        Toggle("Autorizo crear una copia cifrada local", isOn: $consent).disabled(!signing.controls.canBackup)
        if !signing.configured { Text("Primero configurá o importá una sesión.").font(.caption).foregroundStyle(.secondary) }
        else if !signing.controls.canBackup { Text("Se necesita una vigencia comprobable y ninguna operación en curso.").font(.caption).foregroundStyle(.secondary) }
        Button("Preparar respaldo cifrado") {
            Task { @MainActor in
                consent = false
                let context = LAContext()
                do {
                    guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Autorizar respaldo local de ClearSign") else { status = "No se autorizó el respaldo."; return }
                    guard signing.controls.canBackup else { status = "La sesión o la vigencia cambiaron; no se creó el respaldo."; return }
                    let result = try signing.recoveryExport()
                    document = result.0; secret = result.1; exporting = true
                    status = "Elegí En mi iPhone. La clave aparece abajo. El respaldo no es una garantía de recuperación."
                } catch { status = "No se creó el respaldo cifrado." }
            }
        }.disabled(!consent || !signing.controls.canBackup)
        if !secret.isEmpty {
            Text("Clave del respaldo (no compartir)").font(.caption)
            Text(secret).font(.system(.caption, design: .monospaced)).textSelection(.enabled).privacySensitive()
            Button("Ocultar clave y descartar copia temporal") { secret = ""; document = nil }
        }
        if !status.isEmpty { Text(status).font(.footnote) }
        Text("El respaldo permite recuperar la sesión local. No instala nuevas versiones ni reemplaza el ejecutable de A19Core.").font(.caption)
            .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: "A19Core-recovery.clearrecovery") { result in
                switch result { case .success: status = "Archivo cifrado exportado; todavía no se probó la recuperación externa."
                case .failure: secret = ""; document = nil; status = "No se exportó el respaldo." }
            }
    }
}
