import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A dedicated video picker using `PHPickerViewController`.
///
/// We use this instead of SwiftUI `PhotosPicker` for videos because `PhotosPicker` +
/// `loadTransferable` can occasionally freeze the picker UI on some devices.
/// `PHPicker` lets us dismiss immediately and only then start heavy work.
struct VideoPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // No-op
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: VideoPicker

        init(_ parent: VideoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Let the presenting SwiftUI view own dismissal through state.
            // This avoids accidentally dismissing a larger presentation stack
            // such as the Stereo 3D flow.

            guard let provider = results.first?.itemProvider else {
                DispatchQueue.main.async { self.parent.onCancel() }
                return
            }

            let movieType = UTType.movie.identifier
            guard provider.hasItemConformingToTypeIdentifier(movieType) else {
                DispatchQueue.main.async { self.parent.onCancel() }
                return
            }

            provider.loadFileRepresentation(forTypeIdentifier: movieType) { url, error in
                if let error = error {
                    print("VideoPicker loadFileRepresentation error:", error)
                    DispatchQueue.main.async { self.parent.onCancel() }
                    return
                }
                guard let url = url else {
                    DispatchQueue.main.async { self.parent.onCancel() }
                    return
                }

                // Copy into our own temp location so it persists after the provider cleans its temp.
                let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let dst = tmpDir.appendingPathComponent("picked_video_\(UUID().uuidString).\(ext)")

                do {
                    if FileManager.default.fileExists(atPath: dst.path) {
                        try FileManager.default.removeItem(at: dst)
                    }
                    try FileManager.default.copyItem(at: url, to: dst)
                    DispatchQueue.main.async { self.parent.onPicked(dst) }
                } catch {
                    print("VideoPicker copy error:", error)
                    DispatchQueue.main.async { self.parent.onCancel() }
                }
            }
        }
    }
}
