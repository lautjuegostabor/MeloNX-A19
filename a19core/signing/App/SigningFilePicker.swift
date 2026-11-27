import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor final class SigningFilePicker: ObservableObject {
    static let shared = SigningFilePicker()
    struct Request: Identifiable {
        let id = UUID()
        let types: [UTType]
    }
    @Published var request: Request?
    private var completion: ((URL?) -> Void)?
    func pick(types: [UTType], completion: @escaping (URL?) -> Void) {
        guard request == nil else { completion(nil); return }
        self.completion=completion
        request=Request(types:types)
    }
    func finish(_ url: URL?) {
        let handler=completion
        completion=nil
        request=nil
        handler?(url)
    }
    func dismissed() {
        guard completion != nil else { return }
        finish(nil)
    }
}
struct SigningDocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let complete: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(complete:complete) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker=UIDocumentPickerViewController(forOpeningContentTypes:types,asCopy:false)
        picker.allowsMultipleSelection=false
        picker.delegate=context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let complete: (URL?) -> Void
        init(complete:@escaping(URL?)->Void){self.complete=complete}
        func documentPicker(_ controller: UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) { complete(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { complete(nil) }
    }
}
