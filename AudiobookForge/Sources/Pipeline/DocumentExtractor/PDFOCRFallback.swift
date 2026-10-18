import Foundation
import PDFKit
import Vision
import AppKit

/// Renders a PDF page to a bitmap and runs it through Vision's text
/// recognizer. Used only when normal text extraction yields too little text
/// per page, which usually means the PDF is a scan/image without an
/// embedded text layer.
enum PDFOCRFallback {
    /// Average extractable characters per page below this is treated as
    /// "probably a scanned document".
    static let charsPerPageThreshold = 40

    static func needsOCR(pageTexts: [String]) -> Bool {
        guard !pageTexts.isEmpty else { return true }
        let totalChars = pageTexts.reduce(0) { $0 + $1.trimmingCharacters(in: .whitespacesAndNewlines).count }
        let average = Double(totalChars) / Double(pageTexts.count)
        return average < Double(charsPerPageThreshold)
    }

    static func recognizeText(on page: PDFPage) -> String {
        guard let cgImage = renderImage(for: page) else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func renderImage(for page: PDFPage, scale: CGFloat = 2.0) -> CGImage? {
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }

        let pixelSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(pixelSize.width),
                height: Int(pixelSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: pixelSize))
        context.scaleBy(x: scale, y: scale)

        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext
        page.draw(with: .mediaBox, to: context)
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
    }
}
