import Foundation
import PDFKit
import CoreGraphics

/// Finds figures on a PDF page *with their position*, by walking the page's
/// content stream instead of only listing the resource dictionary:
/// - raster images: every `Do` of an image XObject (also inside form
///   XObjects) and every inline image, placed via the current transform;
/// - vector figures: clusters of painted paths (schemas, diagrams, ruled
///   tables) that carry label-like text rather than prose.
///
/// Positions matter for two things downstream: dropping the figure's own
/// label text ("rER", "N*", "a b") from the narration, and inserting an
/// image description exactly where the figure sits. Nothing is decoded
/// here — only geometry and the encoded byte size — so a 700-page
/// textbook with thousands of tiny icons scans in seconds.
enum PDFFigureDetector {
    struct PlacedImage: Equatable {
        let rect: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
        let encodedBytes: Int
    }

    struct Figure: Equatable {
        enum Kind: String { case raster, vector }
        var rect: CGRect
        var kind: Kind
        var pixelWidth: Int
        var pixelHeight: Int
        var encodedBytes: Int
    }

    struct Thresholds {
        var minimumPixelSize: Int = 180
        var minimumAreaFraction: Double = 0.03
        var minimumKilobytes: Int = 8
        var maximumAspectRatio: Double = 6
        var detectVectorFigures: Bool = true
    }

    // MARK: Content stream scan

    struct ScanResult {
        var images: [PlacedImage] = []
        var paintedPaths: [CGRect] = []
    }

    static func scan(page: PDFPage) -> ScanResult {
        guard let pageRef = page.pageRef else { return ScanResult() }
        let state = ScanState()
        let contentStream = CGPDFContentStreamCreateWithPage(pageRef)
        state.scan(contentStream, ctm: .identity, depth: 0)
        return ScanResult(images: state.images, paintedPaths: state.paths)
    }

    // MARK: Figure assembly

    /// Turns the raw scan into figures: size/byte/aspect filters for raster
    /// images (logos, icons, rules and bullets drop out), merging of
    /// overlapping image tiles (one figure split into several parts), and
    /// vector clusters that look like diagrams rather than text boxes.
    static func figures(on page: PDFPage, lines: [PDFColumnTextExtractor.Line], thresholds: Thresholds) -> [Figure] {
        let pageBounds = page.bounds(for: .mediaBox)
        let pageArea = max(pageBounds.width * pageBounds.height, 1)
        let scan = scan(page: page)

        var figures: [Figure] = []
        for image in scan.images {
            let rect = image.rect.intersection(pageBounds)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
            // Full-page backgrounds/scans aren't figures.
            if rect.width * rect.height > pageArea * 0.85 { continue }
            figures.append(Figure(rect: rect, kind: .raster, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight, encodedBytes: image.encodedBytes))
        }
        figures = mergeOverlapping(figures)
        figures = figures.filter { passes($0, pageArea: pageArea, thresholds: thresholds) }

        if thresholds.detectVectorFigures {
            for cluster in clusterPaths(scan.paintedPaths, pageBounds: pageBounds) where cluster.count >= 6 {
                let rect = cluster.rect
                guard rect.width * rect.height >= pageArea * thresholds.minimumAreaFraction,
                      rect.width * rect.height < pageArea * 0.85,
                      !figures.contains(where: { $0.rect.intersects(rect) && overlapFraction($0.rect, rect) > 0.5 }) else { continue }
                let inside = lines.filter { rect.insetBy(dx: -4, dy: -4).contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
                let labelLike = inside.filter { isLabelLike($0.text) }.count
                // A shaded "Merke"-box or a framed paragraph contains prose;
                // a diagram or table contains labels. Only the latter is a
                // figure.
                guard inside.isEmpty || Double(labelLike) / Double(inside.count) >= 0.6 else { continue }
                let scale = 2.0
                figures.append(Figure(rect: rect, kind: .vector, pixelWidth: Int(rect.width * scale), pixelHeight: Int(rect.height * scale), encodedBytes: Int.max))
            }
        }
        return mergeOverlapping(figures).sorted { $0.rect.maxY > $1.rect.maxY }
    }

    static func passes(_ figure: Figure, pageArea: CGFloat, thresholds: Thresholds) -> Bool {
        let area = figure.rect.width * figure.rect.height
        guard area >= pageArea * thresholds.minimumAreaFraction else { return false }
        guard min(figure.pixelWidth, figure.pixelHeight) >= thresholds.minimumPixelSize else { return false }
        guard figure.encodedBytes >= thresholds.minimumKilobytes * 1024 else { return false }
        let aspect = max(figure.rect.width, figure.rect.height) / max(min(figure.rect.width, figure.rect.height), 1)
        return aspect <= thresholds.maximumAspectRatio
    }

    /// Short, non-sentence text: typical for labels inside figures and
    /// table cells ("rER", "N*", "a b", "10 µm", "PZ*").
    static func isLabelLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if PDFFigureDetector.isCaptionStart(trimmed) { return false }
        let words = trimmed.split(separator: " ")
        if trimmed.count <= 30 && words.count <= 4 { return true }
        return false
    }

    private static let captionRegex = try! NSRegularExpression(
        pattern: #"^(Abb\.|Abbildung|Fig\.|Figure|Bild|Tab\.|Tabelle|Table|Schema|Grafik)\s*\d+[\.\-–\d]*"#,
        options: [.caseInsensitive]
    )

    static func isCaptionStart(_ text: String) -> Bool {
        captionRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: Geometry helpers

    private static func overlapFraction(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return (intersection.width * intersection.height) / max(min(a.width * a.height, b.width * b.height), 1)
    }

    /// Merges figures that overlap or touch (tiled images, image + overlay
    /// vector arrows). Keeps the largest pixel size and byte count.
    static func mergeOverlapping(_ figures: [Figure]) -> [Figure] {
        var result = figures
        var merged = true
        while merged {
            merged = false
            outer: for i in result.indices {
                for j in result.indices where j > i {
                    // ~14 pt covers the gutter between panels "a b c" of one
                    // multi-part figure, so it becomes one figure with one
                    // description instead of several fragments.
                    if result[i].rect.insetBy(dx: -14, dy: -14).intersects(result[j].rect) {
                        let a = result[i], b = result[j]
                        result[i] = Figure(
                            rect: a.rect.union(b.rect),
                            kind: a.kind == .raster || b.kind == .raster ? .raster : .vector,
                            pixelWidth: max(a.pixelWidth, b.pixelWidth),
                            pixelHeight: max(a.pixelHeight, b.pixelHeight),
                            encodedBytes: max(a.encodedBytes, b.encodedBytes)
                        )
                        result.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return result
    }

    private struct PathCluster {
        var rect: CGRect
        var count: Int
    }

    /// Groups painted path boxes that lie within a few points of each
    /// other. Page-spanning rules and full-page backgrounds are ignored.
    private static func clusterPaths(_ paths: [CGRect], pageBounds: CGRect) -> [PathCluster] {
        let candidates = paths.filter { rect in
            let isHairlineRule = (rect.height < 1.5 && rect.width > pageBounds.width * 0.5) || (rect.width < 1.5 && rect.height > pageBounds.height * 0.5)
            let isBackground = rect.width * rect.height > pageBounds.width * pageBounds.height * 0.5
            return !isHairlineRule && !isBackground && (rect.width > 0.5 || rect.height > 0.5)
        }
        var clusters: [PathCluster] = []
        for rect in candidates {
            var current = PathCluster(rect: rect, count: 1)
            var index = 0
            while index < clusters.count {
                if clusters[index].rect.insetBy(dx: -8, dy: -8).intersects(current.rect) {
                    current = PathCluster(rect: current.rect.union(clusters[index].rect), count: current.count + clusters[index].count)
                    clusters.remove(at: index)
                    index = 0
                } else {
                    index += 1
                }
            }
            clusters.append(current)
        }
        return clusters
    }
}

// MARK: - Content stream scanner

/// Mutable state for one page scan. Tracks the graphics-state transform
/// stack and the current path's bounding box; records image placements and
/// painted path boxes in page coordinates.
private final class ScanState {
    var images: [PDFFigureDetector.PlacedImage] = []
    var paths: [CGRect] = []

    private var ctmStack: [CGAffineTransform] = []
    private var ctm: CGAffineTransform = .identity
    private var currentPath: CGRect = .null
    private var contentStreams: [CGPDFContentStreamRef] = []
    private var depth = 0
    private var visitedForms = Set<Int>()

    func scan(_ contentStream: CGPDFContentStreamRef, ctm initial: CGAffineTransform, depth: Int) {
        guard depth < 6 else { return }
        let savedCTM = ctm
        let savedStack = ctmStack
        ctm = initial
        ctmStack = []
        contentStreams.append(contentStream)
        self.depth = depth

        let table = CGPDFOperatorTableCreate()!
        Self.register(table)
        let scanner = CGPDFScannerCreate(contentStream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)

        contentStreams.removeLast()
        ctm = savedCTM
        ctmStack = savedStack
        self.depth = max(0, depth - 1)
    }

    fileprivate static func state(_ info: UnsafeMutableRawPointer?) -> ScanState {
        Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
    }

    fileprivate static func popNumbers(_ scanner: CGPDFScannerRef, count: Int) -> [CGFloat]? {
        var values: [CGFloat] = []
        for _ in 0..<count {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values.insert(CGFloat(value), at: 0)
        }
        return values
    }

    private func addPoint(_ x: CGFloat, _ y: CGFloat) {
        let p = CGPoint(x: x, y: y).applying(ctm)
        let r = CGRect(origin: p, size: .zero)
        currentPath = currentPath.isNull ? r : currentPath.union(r)
    }

    private func paint() {
        if !currentPath.isNull { paths.append(currentPath.standardized) }
        currentPath = .null
    }

    private static func register(_ table: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let s = ScanState.state(info); s.ctmStack.append(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = ScanState.state(info); if let last = s.ctmStack.popLast() { s.ctm = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let v = ScanState.popNumbers(scanner, count: 6) else { return }
            let s = ScanState.state(info)
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let v = ScanState.popNumbers(scanner, count: 2) else { return }
            ScanState.state(info).addPoint(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let v = ScanState.popNumbers(scanner, count: 2) else { return }
            ScanState.state(info).addPoint(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let v = ScanState.popNumbers(scanner, count: 6) else { return }
            let s = ScanState.state(info); s.addPoint(v[0], v[1]); s.addPoint(v[2], v[3]); s.addPoint(v[4], v[5])
        }
        for op in ["v", "y"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                guard let v = ScanState.popNumbers(scanner, count: 4) else { return }
                let s = ScanState.state(info); s.addPoint(v[0], v[1]); s.addPoint(v[2], v[3])
            }
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let v = ScanState.popNumbers(scanner, count: 4) else { return }
            let s = ScanState.state(info); s.addPoint(v[0], v[1]); s.addPoint(v[0] + v[2], v[1] + v[3])
        }
        for op in ["f", "F", "f*", "B", "B*", "b", "b*", "S", "s"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in ScanState.state(info).paint() }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in ScanState.state(info).currentPath = .null }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            var namePtr: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &namePtr), let namePtr else { return }
            ScanState.state(info).handleXObject(named: String(cString: namePtr), scanner: scanner)
        }
        CGPDFOperatorTableSetCallback(table, "EI") { scanner, info in
            // Inline image: occupies the unit square under the CTM.
            var stream: CGPDFStreamRef?
            let s = ScanState.state(info)
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bytes = 0
            if CGPDFScannerPopStream(scanner, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) {
                if !CGPDFDictionaryGetInteger(dict, "W", &width) { CGPDFDictionaryGetInteger(dict, "Width", &width) }
                if !CGPDFDictionaryGetInteger(dict, "H", &height) { CGPDFDictionaryGetInteger(dict, "Height", &height) }
                var format: CGPDFDataFormat = .raw
                bytes = (CGPDFStreamCopyData(stream, &format) as Data?)?.count ?? 0
            }
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm).standardized
            s.images.append(.init(rect: rect, pixelWidth: Int(width), pixelHeight: Int(height), encodedBytes: bytes))
        }
    }

    private func handleXObject(named name: String, scanner: CGPDFScannerRef) {
        guard let contentStream = contentStreams.last,
              let object = CGPDFContentStreamGetResource(contentStream, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
        var subtypePtr: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtypePtr), let subtypePtr else { return }

        switch String(cString: subtypePtr) {
        case "Image":
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0, length: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(dict, "Width", &width)
            CGPDFDictionaryGetInteger(dict, "Height", &height)
            CGPDFDictionaryGetInteger(dict, "Length", &length)
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm).standardized
            images.append(.init(rect: rect, pixelWidth: Int(width), pixelHeight: Int(height), encodedBytes: Int(length)))
        case "Form":
            // Each form is scanned once per page — guards against
            // self-referencing forms and endlessly repeated icon forms.
            let key = unsafeBitCast(stream, to: Int.self)
            guard !visitedForms.contains(key) else { return }
            visitedForms.insert(key)
            var matrix = CGAffineTransform.identity
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                var values: [CGFloat] = []
                for i in 0..<6 {
                    var number: CGPDFReal = 0
                    CGPDFArrayGetNumber(array, i, &number)
                    values.append(CGFloat(number))
                }
                matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            }
            var resources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
            let formStream = CGPDFContentStreamCreateWithStream(stream, resources ?? CGPDFStreamGetDictionary(stream)!, contentStream)
            let savedPath = currentPath
            scan(formStream, ctm: matrix.concatenating(ctm), depth: depth + 1)
            currentPath = savedPath
        default:
            break
        }
    }
}
