import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// Pulls embedded raster images (figures, charts, scanned tables) out of a
/// PDF page's resource dictionary. Decodes both JPEG-encoded (DCTDecode)
/// and lossless FlateDecode (PNG-style bitmaps embedded by LaTeX/Office)
/// image XObjects into JPEG format suitable for multimodal LLM vision models.
enum PDFImageExtractor {
    struct ExtractedImage {
        let jpegData: Data
        let width: Int
        let height: Int
        let contentHash: String
    }

    static func images(on page: PDFPage) -> [ExtractedImage] {
        guard let pageRef = page.pageRef, let pageDict = pageRef.dictionary else { return [] }

        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources), let resources else { return [] }

        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return [] }

        var results: [ExtractedImage] = []
        CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
            autoreleasepool {
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
                guard let streamDict = CGPDFStreamGetDictionary(stream) else { return }

                var subtypeName: UnsafePointer<Int8>?
                guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtypeName), let subtypeName,
                      String(cString: subtypeName) == "Image" else { return }

                var width: CGPDFInteger = 0
                var height: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(streamDict, "Width", &width)
                CGPDFDictionaryGetInteger(streamDict, "Height", &height)
                guard width > 0, height > 0 else { return }

                var format: CGPDFDataFormat = .raw
                guard let cfData = CGPDFStreamCopyData(stream, &format) else { return }
                let nsData = cfData as Data

                var finalJpegData: Data?

                if format == .jpegEncoded {
                    finalJpegData = nsData
                } else {
                    var bitsPerComponent: CGPDFInteger = 8
                    CGPDFDictionaryGetInteger(streamDict, "BitsPerComponent", &bitsPerComponent)

                    var colorSpace = CGColorSpaceCreateDeviceRGB()
                    var colorSpaceObj: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(streamDict, "ColorSpace", &colorSpaceObj), let colorSpaceObj {
                        var csName: UnsafePointer<Int8>?
                        if CGPDFObjectGetValue(colorSpaceObj, .name, &csName), let csName {
                            let name = String(cString: csName)
                            if name == "DeviceGray" { colorSpace = CGColorSpaceCreateDeviceGray() }
                            else if name == "DeviceCMYK" { colorSpace = CGColorSpaceCreateDeviceCMYK() }
                        }
                    }

                    let numComponents = colorSpace.numberOfComponents
                    let bpc = Int(bitsPerComponent)
                    let bytesPerRow = (Int(width) * numComponents * bpc + 7) / 8

                    if let provider = CGDataProvider(data: cfData),
                       let cgImg = CGImage(
                        width: Int(width),
                        height: Int(height),
                        bitsPerComponent: bpc,
                        bitsPerPixel: bpc * numComponents,
                        bytesPerRow: bytesPerRow,
                        space: colorSpace,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                        provider: provider,
                        decode: nil,
                        shouldInterpolate: true,
                        intent: .defaultIntent
                    ) {
                        let destData = NSMutableData()
                        if let dest = CGImageDestinationCreateWithData(destData, UTType.jpeg.identifier as CFString, 1, nil) {
                            CGImageDestinationAddImage(dest, cgImg, nil)
                            if CGImageDestinationFinalize(dest) {
                                finalJpegData = destData as Data
                            }
                        }
                    }
                }

                guard let jpegData = finalJpegData, !jpegData.isEmpty else { return }

                let hash = SHA256.hash(data: jpegData).compactMap { String(format: "%02x", $0) }.joined()
                results.append(ExtractedImage(jpegData: jpegData, width: Int(width), height: Int(height), contentHash: hash))
            }
            return true
        }, nil)

        return results
    }

    /// Images whose content hash recurs on a large fraction of pages are
    /// almost certainly a repeated logo/watermark rather than a real figure.
    static func filterRepeatedImages(_ imagesByPage: [[ExtractedImage]], pageCount: Int) -> [[ExtractedImage]] {
        guard pageCount > 3 else { return imagesByPage }

        var hashCounts: [String: Int] = [:]
        for pageImages in imagesByPage {
            for image in Set(pageImages.map(\.contentHash)) {
                hashCounts[image, default: 0] += 1
            }
        }

        let threshold = max(3, Int(Double(pageCount) * 0.3))
        let repeatedHashes = Set(hashCounts.filter { $0.value >= threshold }.keys)

        return imagesByPage.map { pageImages in
            pageImages.filter { !repeatedHashes.contains($0.contentHash) }
        }
    }
}
