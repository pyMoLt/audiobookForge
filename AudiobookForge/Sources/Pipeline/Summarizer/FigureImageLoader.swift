import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Produces the JPEG that is sent to the vision model for one figure.
///
/// PDF figures are rendered from the page region rather than extracted
/// from the image XObject: the rendering includes overlaid labels, arrows
/// and scale bars (which the narration dropped), works identically for
/// vector diagrams, and avoids the colour-space/encoding pitfalls of raw
/// image streams.
enum FigureImageLoader {
    static let maximumPixels: CGFloat = 1600

    static func renderPDFRegion(document: PDFDocument, pageIndex: Int, rect: CGRect) -> Data? {
        autoreleasepool {
            guard let page = document.page(at: pageIndex) else { return nil }
            let pageBounds = page.bounds(for: .mediaBox)
            let region = rect.insetBy(dx: -4, dy: -4).intersection(pageBounds)
            guard !region.isNull, region.width > 4, region.height > 4 else { return nil }

            let scale = min(maximumPixels / max(region.width, region.height), 4)
            let width = Int(region.width * scale), height = Int(region.height * scale)
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -region.minX, y: -region.minY)
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { return nil }
            return jpeg(image)
        }
    }

    /// Loads an EPUB image from the unpacked archive, downscaled to the
    /// same maximum size.
    static func loadArchiveImage(archiveRoot: URL, path: String) -> Data? {
        autoreleasepool {
            let url = archiveRoot.appendingPathComponent(path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return jpeg(image)
        }
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        autoreleasepool {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? (data as Data) : nil
        }
    }
}
