import AppKit
import CoreGraphics

/// Turns any picture into pixel art (v3.2: book covers on the shelf, in the
/// player and the sidebar): area-averaged downscale to a few dozen pixels,
/// palette reduced with k-means, drawn later without smoothing
/// (`.interpolation(.none)`).
enum PixelArt {
    /// Art-pixel widths in use — higher resolution so cover typography and art
    /// are clearly recognizable while retaining crisp nearest-neighbor pixel art.
    static let widthSteps = [32, 48, 64, 96, 128, 160, 200]

    /// Art width for a cover shown `points` wide: an art pixel stays about
    /// 1.8–2.0 pt big, ensuring readable covers and crisp pixel aesthetics.
    static func artWidth(forPoints points: CGFloat) -> Int {
        let wanted = Int((points / 2.0).rounded())
        return widthSteps.first { $0 >= wanted } ?? widthSteps.last!
    }

    static func pixelate(_ image: CGImage, artWidth: Int, colours: Int = 36) -> CGImage? {
        let artHeight = max(1, Int((Double(artWidth) * Double(image.height) / Double(image.width)).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: artWidth, height: artHeight, bitsPerComponent: 8, bytesPerRow: artWidth * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high // area average
        context.draw(image, in: CGRect(x: 0, y: 0, width: artWidth, height: artHeight))
        guard let data = context.data else { return nil }
        let count = artWidth * artHeight
        let pixels = data.bindMemory(to: UInt8.self, capacity: count * 4)
        var points = [SIMD3<Float>](repeating: .zero, count: count)
        for i in 0..<count {
            points[i] = SIMD3(Float(pixels[i * 4]), Float(pixels[i * 4 + 1]), Float(pixels[i * 4 + 2]))
        }
        let palette = kMeans(points, k: min(colours, count))
        for i in 0..<count {
            let c = palette[nearest(points[i], palette)]
            pixels[i * 4] = UInt8(c.x.rounded()); pixels[i * 4 + 1] = UInt8(c.y.rounded()); pixels[i * 4 + 2] = UInt8(c.z.rounded())
            pixels[i * 4 + 3] = 255
        }
        return context.makeImage()
    }

    private static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return 2 * d.x * d.x + 4 * d.y * d.y + 3 * d.z * d.z
    }

    private static func nearest(_ point: SIMD3<Float>, _ palette: [SIMD3<Float>]) -> Int {
        var best = 0, bestDistance = Float.greatestFiniteMagnitude
        for (index, colour) in palette.enumerated() {
            let d = distance(point, colour)
            if d < bestDistance { bestDistance = d; best = index }
        }
        return best
    }

    /// Deterministic k-means (spread seeding over the sorted points), so
    /// the same cover always gives the same pixel art.
    private static func kMeans(_ points: [SIMD3<Float>], k: Int) -> [SIMD3<Float>] {
        guard k > 0 else { return [] }
        let sorted = points.sorted { ($0.x + $0.y + $0.z) < ($1.x + $1.y + $1.z) }
        var centres = (0..<k).map { sorted[min(sorted.count - 1, ($0 * sorted.count) / k + sorted.count / (2 * k))] }
        var assignment = [Int](repeating: 0, count: points.count)
        for _ in 0..<8 {
            for (i, point) in points.enumerated() { assignment[i] = nearest(point, centres) }
            var sums = [SIMD3<Float>](repeating: .zero, count: k), counts = [Float](repeating: 0, count: k)
            for (i, point) in points.enumerated() { sums[assignment[i]] += point; counts[assignment[i]] += 1 }
            for c in 0..<k where counts[c] > 0 { centres[c] = sums[c] / counts[c] }
        }
        return centres
    }
}
