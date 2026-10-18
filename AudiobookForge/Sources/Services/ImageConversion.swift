import Foundation
import AppKit

enum ImageConversion {
    /// Normalizes any image data (PNG, JPEG, whatever the source format was)
    /// to JPEG, so the whole app deals with one consistent cover format
    /// regardless of whether the cover came from an EPUB's manifest or was
    /// rendered from a PDF's first page.
    static func toJPEG(_ data: Data, quality: CGFloat = 0.85) -> Data? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
