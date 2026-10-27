import AppKit
import SwiftUI
import QuickLookThumbnailing

/// Cover pictures for the file list (0.22): Quick Look's thumbnail of each file
/// (a PDF's first page, an EPUB's cover), cached; files only in iCloud show their
/// icon, so nothing is downloaded.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    func image(for path: String, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        let key = "\(size)|\(path)" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        let url = URL(fileURLWithPath: path)
        let icon = NSWorkspace.shared.icon(forFile: path)
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        guard status != .notDownloaded else {
            completion(icon)
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage ?? icon
            self?.cache.setObject(image, forKey: key)
            DispatchQueue.main.async { completion(image) }
        }
    }
}

/// A file's cover, loaded when the row appears.
struct ThumbnailView: View {
    let path: String
    var size: CGFloat = 40
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.secondary.opacity(0.08)
            }
        }
        .frame(width: size * 0.75, height: size)
        .onAppear {
            Thumbnails.shared.image(for: path, size: size) { image = $0 }
        }
        .id(path)
    }
}
