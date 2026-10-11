import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PKGDocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.item],
            asCopy: true
        )

        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator

        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            // Secure/move imported URLs while the picker still owns them.
            // ContentView closes the SwiftUI sheet after onPick returns.
            self.onPick(urls)
        }

        func documentPickerWasCancelled(
            _ controller: UIDocumentPickerViewController
        ) {
            controller.dismiss(animated: true)
        }
    }
}
