import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// A helper to import video files via PhotosPicker without loading the entire data into memory.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            // CRITICAL:
            // Do NOT do any large file I/O (copy/move) here.
            // This importing closure is executed while PhotosPicker is still presenting.
            // Any heavy work here will freeze the picker UI (even the close button).
            //
            // Return the temporary file URL immediately, then copy/move it later
            // on a background task *after* the picker dismisses.
            return MovieFile(url: received.file)
        }
    }
}
