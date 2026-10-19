// Turns generated "pixel-look" scene images (JPEG, uneven grid) into clean
// pixel art: detects the pixel grid, samples one colour per cell, reduces the
// palette and writes a native-resolution PNG (the app upscales it without
// smoothing) plus a 4× preview for review.
//
// Usage:
//   swiftc -O scripts/pixelize_scenes.swift -o /tmp/pixelize
//   /tmp/pixelize <out-dir> [--colors 40] [--cell <px>] [--key] <image>...
//   --size 320x180: fixed output grid (use this — layers must line up).
//   --mean: average cells instead of median (dithered skies).
//   --key: chroma-key green becomes transparent (fire opening, layer skies).
//
// Only Apple frameworks (CoreGraphics/ImageIO) — no extra dependency.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGBA { var r: Float, g: Float, b: Float }

struct Bitmap {
    let width: Int, height: Int
    var pixels: [UInt8] // RGBA8

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        pixels = [UInt8](repeating: 255, count: width * height * 4)
    }

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        width = image.width; height = image.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !drawn { return nil }
    }

    func color(_ x: Int, _ y: Int) -> RGBA {
        let i = (y * width + x) * 4
        return RGBA(r: Float(pixels[i]), g: Float(pixels[i + 1]), b: Float(pixels[i + 2]))
    }

    mutating func set(_ x: Int, _ y: Int, _ c: RGBA) {
        let i = (y * width + x) * 4
        pixels[i] = UInt8(max(0, min(255, c.r.rounded())))
        pixels[i + 1] = UInt8(max(0, min(255, c.g.rounded())))
        pixels[i + 2] = UInt8(max(0, min(255, c.b.rounded())))
        pixels[i + 3] = 255
    }

    mutating func clear(_ x: Int, _ y: Int) {
        let i = (y * width + x) * 4
        pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
    }

    func isOpaque(_ x: Int, _ y: Int) -> Bool { pixels[(y * width + x) * 4 + 3] > 0 }

    /// Chroma-key green (#00FF00-ish) marks areas that become transparent —
    /// the fire opening, the sky behind train layers. Dark foliage stays.
    func isKey(_ x: Int, _ y: Int) -> Bool {
        let c = color(x, y)
        return c.g > 150 && c.g > c.r + 80 && c.g > c.b + 80
    }

    func luma(_ x: Int, _ y: Int) -> Float {
        let c = color(x, y); return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    func write(_ url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var copy = pixels
        let image: CGImage? = copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "pixelize", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "pixelize", code: 2, userInfo: [NSLocalizedDescriptionKey: "finalize failed \(url.path)"])
        }
    }
}

// MARK: Grid detection

/// Edge profile along one axis: mean absolute luma step between neighbours.
func edgeProfile(_ bitmap: Bitmap, horizontal: Bool) -> [Float] {
    let length = horizontal ? bitmap.width - 1 : bitmap.height - 1
    let across = horizontal ? bitmap.height : bitmap.width
    var profile = [Float](repeating: 0, count: length)
    for i in 0..<length {
        var sum: Float = 0
        for j in stride(from: 0, to: across, by: 2) {
            sum += horizontal ? abs(bitmap.luma(i + 1, j) - bitmap.luma(i, j)) : abs(bitmap.luma(j, i + 1) - bitmap.luma(j, i))
        }
        profile[i] = sum / Float(across / 2)
    }
    return profile
}

/// Best (period, phase) for a possibly fractional grid: edges should sit on
/// phase + k·period. Score = edge energy on grid lines / average energy.
func detectGrid(_ profile: [Float], periods: ClosedRange<Double> = 2.0...12.0) -> (period: Double, phase: Double, score: Double) {
    let mean = Double(profile.reduce(0, +)) / Double(profile.count)
    var best = (period: 1.0, phase: 0.0, score: 0.0)
    var period = periods.lowerBound
    while period <= periods.upperBound + 1e-9 {
        var phase = 0.0
        while phase < period {
            var sum = 0.0, count = 0
            var x = phase
            while x < Double(profile.count) - 1 {
                sum += Double(profile[Int(x.rounded(.down))]); count += 1
                x += period
            }
            let score = count > 0 ? (sum / Double(count)) / max(mean, 1e-6) : 0
            // Prefer the larger period when scores tie (a 4-grid also scores on 2).
            if score > best.score * 1.03 || (score > best.score * 0.97 && period > best.period * 1.5) {
                best = (period, phase, score)
            }
            phase += 0.1
        }
        period += 0.05
    }
    return best
}

// MARK: Downsampling

/// One colour per cell: median of the cell's inner pixels (cell borders carry
/// JPEG ringing and anti-aliasing from the generator).
func downsample(_ bitmap: Bitmap, periodX: Double, phaseX: Double, periodY: Double, phaseY: Double, chromaKey: Bool,
                size: (Int, Int)? = nil, useMean: Bool = false) -> Bitmap {
    var startX = phaseX - periodX * (phaseX / periodX).rounded(.down) - periodX + 1
    var startY = phaseY - periodY * (phaseY / periodY).rounded(.down) - periodY + 1
    var columns = Int(((Double(bitmap.width) - startX) / periodX).rounded(.down))
    var rows = Int(((Double(bitmap.height) - startY) / periodY).rounded(.down))
    var periodX = periodX, periodY = periodY
    if let size {
        // Fixed grid: identical cells for every image, so layers (fireplace
        // with and without the keyed opening) line up pixel for pixel.
        (columns, rows) = size
        periodX = Double(bitmap.width) / Double(columns); periodY = Double(bitmap.height) / Double(rows)
        startX = 0; startY = 0
    }
    var out = Bitmap(width: columns, height: rows)
    for row in 0..<rows {
        for column in 0..<columns {
            let x0 = startX + Double(column) * periodX, y0 = startY + Double(row) * periodY
            // Keyed layers sample the whole cell: thin dark lines on the key
            // (wires, twigs) would otherwise fall between the samples.
            let inset = chromaKey ? 0.0 : 0.25
            let xa = max(0, Int((x0 + periodX * inset).rounded())), xb = min(bitmap.width - 1, Int((x0 + periodX * (1 - inset)).rounded()))
            let ya = max(0, Int((y0 + periodY * inset).rounded())), yb = min(bitmap.height - 1, Int((y0 + periodY * (1 - inset)).rounded()))
            // Pure key pixels first: the halo rule below only applies next to
            // the key, so genuinely green things (curtains, seats) stay.
            var pureKey = 0
            if chromaKey {
                for y in ya...max(ya, yb) { for x in xa...max(xa, xb) where bitmap.isKey(x, y) { pureKey += 1 } }
            }
            var rs: [Float] = [], gs: [Float] = [], bs: [Float] = []
            var dark: [RGBA] = []
            var total = 0
            for y in ya...max(ya, yb) {
                for x in xa...max(xa, xb) {
                    total += 1
                    if chromaKey && bitmap.isKey(x, y) { continue }
                    var c = bitmap.color(x, y)
                    if pureKey > 0 && c.g - max(c.r, c.b) > 28 {
                        // Bright halo pixels blended with the key: drop them.
                        // Dark ones are a thin line mixed with the key: keep
                        // them with the green removed.
                        if c.g >= 110 { continue }
                        c.g = max(c.r, c.b) + 8
                    }
                    if pureKey > 0 && 0.299 * c.r + 0.587 * c.g + 0.114 * c.b < 70 { dark.append(c) }
                    rs.append(c.r); gs.append(c.g); bs.append(c.b)
                }
            }
            func median(_ v: [Float]) -> Float { let s = v.sorted(); return s[s.count / 2] }
            func mean(_ v: [Float]) -> Float { v.reduce(0, +) / Float(v.count) }
            var c: RGBA
            if rs.count * 4 >= total {
                // Mean reads dithered areas (skies) as the colour they stand
                // for; median picks one of the dither colours → noise.
                c = useMean && pureKey == 0 ? RGBA(r: mean(rs), g: mean(gs), b: mean(bs)) : RGBA(r: median(rs), g: median(gs), b: median(bs))
            } else if dark.count >= 2 {
                // Line rescue: a 1-px wire covers less than a quarter of a
                // cell but must stay continuous.
                c = RGBA(r: median(dark.map(\.r)), g: median(dark.map(\.g)), b: median(dark.map(\.b)))
            } else {
                out.clear(column, row); continue
            }
            if pureKey > 0 { c.g = min(c.g, max(c.r, c.b) + 12) }
            out.set(column, row, c)
        }
    }
    return out
}

// MARK: Palette (k-means, deterministic k-means++ seeding)

func quantize(_ bitmap: inout Bitmap, colors k: Int) -> [RGBA] {
    var points: [RGBA] = []
    var positions: [(Int, Int)] = []
    for y in 0..<bitmap.height { for x in 0..<bitmap.width where bitmap.isOpaque(x, y) { points.append(bitmap.color(x, y)); positions.append((x, y)) } }
    guard points.count > k else { return [] }
    func dist(_ a: RGBA, _ b: RGBA) -> Float {
        // Weighted RGB (close to perceived difference, cheap).
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return 2 * dr * dr + 4 * dg * dg + 3 * db * db
    }
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func next() -> Double { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Double(seed % 1_000_000) / 1_000_000 }
    var centers = [points[points.count / 2]]
    var nearest = points.map { dist($0, centers[0]) }
    while centers.count < k {
        let total = nearest.reduce(0, +)
        var target = Float(next()) * total, index = 0
        while index < points.count - 1 && target > nearest[index] { target -= nearest[index]; index += 1 }
        centers.append(points[index])
        for i in points.indices { nearest[i] = min(nearest[i], dist(points[i], centers.last!)) }
    }
    var assignment = [Int](repeating: 0, count: points.count)
    for _ in 0..<12 {
        for i in points.indices {
            var bestIndex = 0, bestDistance = Float.greatestFiniteMagnitude
            for (c, center) in centers.enumerated() { let d = dist(points[i], center); if d < bestDistance { bestDistance = d; bestIndex = c } }
            assignment[i] = bestIndex
        }
        var sums = [RGBA](repeating: RGBA(r: 0, g: 0, b: 0), count: k), counts = [Float](repeating: 0, count: k)
        for i in points.indices { let a = assignment[i]; sums[a].r += points[i].r; sums[a].g += points[i].g; sums[a].b += points[i].b; counts[a] += 1 }
        for c in 0..<k where counts[c] > 0 { centers[c] = RGBA(r: sums[c].r / counts[c], g: sums[c].g / counts[c], b: sums[c].b / counts[c]) }
    }
    for (i, position) in positions.enumerated() { bitmap.set(position.0, position.1, centers[assignment[i]]) }
    return centers
}

/// Removes single stray pixels (JPEG noise): a pixel whose 4 neighbours
/// mostly (≥3) share one other colour takes that colour. Edges and 1-px
/// lines survive because their neighbours disagree.
func despeckle(_ bitmap: inout Bitmap) -> Int {
    let source = bitmap
    var changed = 0
    func key(_ x: Int, _ y: Int) -> Int {
        guard source.isOpaque(x, y) else { return -1 }
        let c = source.color(x, y); return Int(c.r) << 16 | Int(c.g) << 8 | Int(c.b)
    }
    for y in 1..<(bitmap.height - 1) {
        for x in 1..<(bitmap.width - 1) {
            let own = key(x, y)
            let ring = [(x - 1, y - 1), (x, y - 1), (x + 1, y - 1), (x - 1, y), (x + 1, y), (x - 1, y + 1), (x, y + 1), (x + 1, y + 1)]
            let keys = ring.map { key($0.0, $0.1) }
            // A pixel with a same-coloured 8-neighbour is part of a shape or a
            // (diagonal) line — keep it.
            if keys.contains(own) { continue }
            var counts: [Int: Int] = [:]
            for k in keys { counts[k, default: 0] += 1 }
            guard let (majority, count) = counts.max(by: { $0.value < $1.value }) else { continue }
            if own == -1 {
                // Hole in a shape: fill only when clearly enclosed.
                if count >= 6 { let donor = ring[keys.firstIndex(of: majority)!]; bitmap.set(x, y, source.color(donor.0, donor.1)); changed += 1 }
            } else if majority == -1 {
                // Lone dot in empty space: remove only if nothing opaque touches it.
                if count == 8 { bitmap.clear(x, y); changed += 1 }
            } else if count >= 6 {
                let donor = ring[keys.firstIndex(of: majority)!]
                bitmap.set(x, y, source.color(donor.0, donor.1)); changed += 1
            }
        }
    }
    return changed
}

func upscale(_ bitmap: Bitmap, _ factor: Int) -> Bitmap {
    var out = Bitmap(width: bitmap.width * factor, height: bitmap.height * factor)
    for y in 0..<out.height {
        for x in 0..<out.width {
            if bitmap.isOpaque(x / factor, y / factor) { out.set(x, y, bitmap.color(x / factor, y / factor)) } else { out.clear(x, y) }
        }
    }
    return out
}

// MARK: Main

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    print("usage: pixelize <out-dir> [--colors N] [--cell PX] [--key] <image>..."); exit(1)
}
let outDir = URL(fileURLWithPath: arguments.removeFirst())
var colors = 40
var forcedCell: Double?
var zoom: [Int]?
var chromaKey = false
var fixedSize: (Int, Int)?
var useMean = false
var inputs: [String] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--colors": colors = Int(arguments.removeFirst()) ?? colors
    case "--cell": forcedCell = Double(arguments.removeFirst())
    case "--key": chromaKey = true
    case "--mean": useMean = true
    case "--size":
        let parts = arguments.removeFirst().split(separator: "x").compactMap { Int($0) }
        if parts.count == 2 { fixedSize = (parts[0], parts[1]) }
    // Debug: --zoom x,y,w,h writes an 8× nearest-neighbour crop of the source.
    case "--zoom": zoom = arguments.removeFirst().split(separator: ",").compactMap { Int($0) }
    default: inputs.append(argument)
    }
}
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for path in inputs {
    let url = URL(fileURLWithPath: path)
    guard let bitmap = Bitmap(url: url) else { print("skip \(path): unreadable"); continue }
    if let zoom, zoom.count == 4 {
        var crop = Bitmap(width: zoom[2], height: zoom[3])
        for y in 0..<zoom[3] { for x in 0..<zoom[2] { crop.set(x, y, bitmap.color(min(bitmap.width - 1, zoom[0] + x), min(bitmap.height - 1, zoom[1] + y))) } }
        try upscale(crop, 8).write(outDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_zoom.png"))
        continue
    }
    // A forced cell size (e.g. 1024 px / 320 = 3.2) only searches the phase.
    let range = forcedCell.map { $0...$0 } ?? 2.0...12.0
    let gridX = detectGrid(edgeProfile(bitmap, horizontal: true), periods: range)
    let gridY = detectGrid(edgeProfile(bitmap, horizontal: false), periods: range)
    let periodX = gridX.period, periodY = gridY.period
    var native = downsample(bitmap, periodX: periodX, phaseX: gridX.phase, periodY: periodY, phaseY: gridY.phase, chromaKey: chromaKey, size: fixedSize, useMean: useMean)
    _ = quantize(&native, colors: colors)
    let cleaned = despeckle(&native)
    let name = url.deletingPathExtension().lastPathComponent
    try native.write(outDir.appendingPathComponent("\(name).png"))
    try upscale(native, 4).write(outDir.appendingPathComponent("\(name)_preview4x.png"))
    print(String(format: "%@: %dx%d  grid x %.2f@%.2f (score %.2f)  y %.2f@%.2f (score %.2f)  → %dx%d, %d colours, %d stray px fixed",
                 name, bitmap.width, bitmap.height, gridX.period, gridX.phase, gridX.score, gridY.period, gridY.phase, gridY.score,
                 native.width, native.height, colors, cleaned))
}
