// Generates the animated pixel-art layers for the ambient scenes from the
// cleaned 320×180 backgrounds (scripts/pixelize_scenes.swift):
//   fire: flame sprite sheet sized to the keyed fireplace opening, a light map
//         (where the firelight falls) and a layout JSON for the renderer.
//   rain/storm: periodic rain tiles, ripples, drops on the glass, lightning
//   forest/ocean/cyberpunk/train: glints, fireflies, foam, neon overlays,
//         window lights, parallax layers — plus a layout JSON per scene.
//
// Usage:
//   swiftc -O scripts/make_scene_sprites.swift -o /tmp/make_sprites
//   /tmp/make_sprites <pixelized-dir> <resources-out-dir>
//
// Only Apple frameworks. Deterministic: same input → same output.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Canvas {
    let width: Int, height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        width = image.width; height = image.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }

    func luma(_ x: Int, _ y: Int) -> Double {
        let i = (y * width + x) * 4
        return (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255
    }

    /// Straight (non-premultiplied) colour in, stored premultiplied.
    mutating func set(_ x: Int, _ y: Int, _ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        let i = (y * width + x) * 4
        let a = max(0, min(1, a))
        pixels[i] = UInt8((max(0, min(1, r)) * a * 255).rounded())
        pixels[i + 1] = UInt8((max(0, min(1, g)) * a * 255).rounded())
        pixels[i + 2] = UInt8((max(0, min(1, b)) * a * 255).rounded())
        pixels[i + 3] = UInt8((a * 255).rounded())
    }

    func write(_ url: URL) throws {
        var copy = pixels
        let image: CGImage? = copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "sprites", code: 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "sprites", code: 2) }
    }
}

// Smooth periodic value noise (period in both axes) for looping animation.
func hash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
    var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 2_147_483_647))
    h = (h ^ (h >> 13)) &* 1_274_126_177
    return Double((h ^ (h >> 16)) & 0xFFFF) / 65535
}

func noise(_ x: Double, _ y: Double, periodX: Int, periodY: Int, seed: Int) -> Double {
    let xi = Int(floor(x)), yi = Int(floor(y))
    let fx = x - floor(x), fy = y - floor(y)
    func h(_ a: Int, _ b: Int) -> Double { hash(((a % periodX) + periodX) % periodX, ((b % periodY) + periodY) % periodY, seed) }
    let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
    let top = h(xi, yi) * (1 - sx) + h(xi + 1, yi) * sx
    let bottom = h(xi, yi + 1) * (1 - sx) + h(xi + 1, yi + 1) * sx
    return top * (1 - sy) + bottom * sy
}

// MARK: Fire

/// Pixel-art flame palette, hottest last. Hard steps — no gradients.
let flamePalette: [(Double, Double, Double)] = [
    (0.36, 0.06, 0.04), // deep red
    (0.62, 0.13, 0.05), // red
    (0.86, 0.32, 0.07), // orange
    (0.98, 0.58, 0.15), // light orange
    (1.00, 0.84, 0.42), // yellow
    (1.00, 0.96, 0.78), // core
]

func makeFire(pixelized: URL, out: URL) throws {
    guard let keyed = Canvas(url: pixelized.appendingPathComponent("kamin_chroma key.png")),
          let room = Canvas(url: pixelized.appendingPathComponent("Kamin.png")) else {
        throw NSError(domain: "sprites", code: 3, userInfo: [NSLocalizedDescriptionKey: "Kamin images missing"])
    }
    // Opening = transparent pixels of the keyed image.
    var minX = keyed.width, minY = keyed.height, maxX = 0, maxY = 0
    for y in 0..<keyed.height { for x in 0..<keyed.width where keyed.alpha(x, y) == 0 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    let openW = maxX - minX + 1, openH = maxY - minY + 1
    let frames = 8
    var sheet = Canvas(width: openW * frames, height: openH)
    // Flames sit on the logs and rise as separate tongues: each tongue
    // has its own position, width and height that breathe over the loop
    // (sin/cos of the loop phase → seamless). Hot at the base, dark red at
    // the tips, gaps between tongues.
    let baseY = Double(openH) * 0.78
    let tongues: [(pos: Double, width: Double, height: Double, phase: Double)] = [
        (0.24, 0.09, 0.55, 0.0), (0.36, 0.11, 0.85, 1.7), (0.50, 0.12, 1.00, 3.1),
        (0.62, 0.10, 0.80, 4.4), (0.74, 0.09, 0.60, 5.6), (0.43, 0.06, 0.65, 2.4), (0.57, 0.06, 0.70, 0.9),
    ]
    for frame in 0..<frames {
        let t = Double(frame) / Double(frames)
        let angle = t * 2 * Double.pi
        for y in 0..<openH {
            for x in 0..<openW {
                let u = Double(x) / Double(openW)
                let up = (baseY - Double(y)) / baseY // 0 at the logs, 1 at the top
                // Column height = strongest tongue at this column.
                var columnHeight = 0.0
                for tongue in tongues {
                    let sway = 0.025 * sin(angle * 2 + tongue.phase + up * 3)
                    let d = (u - tongue.pos - sway) / tongue.width
                    let breathe = 0.78 + 0.22 * sin(angle * 2 + tongue.phase)
                    columnHeight = max(columnHeight, tongue.height * breathe * exp(-d * d))
                }
                // Rising noise breaks the edges into licks and loose bits.
                let n = noise(Double(x) * 0.35, Double(y) * 0.28 + t * 12, periodX: 64, periodY: 12, seed: 3)
                let reach = columnHeight * (0.82 + 0.36 * n)
                if up < 0 {
                    // Ember bed between the logs: a thin glowing strip.
                    guard up > -0.12, u > 0.2, u < 0.8, n > 0.35 else { continue }
                    let c = flamePalette[n > 0.7 ? 3 : 2]
                    sheet.set(frame * openW + x, y, c.0, c.1, c.2, 1)
                    continue
                }
                guard up < reach else { continue }
                // Temperature: 1 at the base of a tall column, 0 at its tip.
                let heat = (1 - up / max(reach, 0.01)) * (0.55 + 0.45 * columnHeight) + (n - 0.5) * 0.25
                guard heat > 0.04 else { continue }
                let level = max(0, min(flamePalette.count - 1, Int(heat * Double(flamePalette.count))))
                let c = flamePalette[level]
                sheet.set(frame * openW + x, y, c.0, c.1, c.2, 1)
            }
        }
    }
    try sheet.write(out.appendingPathComponent("scene_fire_flames.png"))

    // Light map: warm light falling from the opening; brighter on light
    // surfaces (stones, rug), soft falloff. Rendered additively at runtime.
    var light = Canvas(width: room.width, height: room.height)
    let cx = Double(minX + openW / 2), cy = Double(maxY) - Double(openH) * 0.25
    let radius = Double(room.width) * 0.55
    for y in 0..<room.height {
        for x in 0..<room.width {
            if keyed.alpha(x, y) == 0 { continue } // the opening itself is the flame layer
            let dx = (Double(x) - cx) / radius, dy = (Double(y) - cy) / (radius * 0.75)
            let d = sqrt(dx * dx + dy * dy)
            guard d < 1 else { continue }
            let falloff = pow(1 - d, 2.2)
            let surface = 0.35 + room.luma(x, y) * 1.6
            // Quantised to a few steps — pixel-art lighting, not a gradient.
            let strength = (min(1, falloff * surface) * 6).rounded(.down) / 6
            guard strength > 0 else { continue }
            light.set(x, y, 1.0, 0.55, 0.22, strength * 0.55)
        }
    }
    try light.write(out.appendingPathComponent("scene_fire_light.png"))

    let layout: [String: Any] = [
        "canvas": [room.width, room.height],
        "opening": [minX, minY, openW, openH],
        "frames": frames,
        "lightCenter": [cx, cy],
    ]
    let data = try JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: out.appendingPathComponent("scene_fire.json"))
    print("fire: opening \(minX),\(minY) \(openW)×\(openH), \(frames) frames")
}


// MARK: Shared helpers

extension Canvas {
    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * width + x) * 4
        let a = max(1, Double(pixels[i + 3])) / 255
        return (Double(pixels[i]) / 255 / a, Double(pixels[i + 1]) / 255 / a, Double(pixels[i + 2]) / 255 / a)
    }

    /// (saturation, value) of a pixel.
    func sv(_ x: Int, _ y: Int) -> (Double, Double) {
        let (r, g, b) = rgb(x, y)
        let mx = max(r, g, b), mn = min(r, g, b)
        return (mx > 0 ? (mx - mn) / mx : 0, mx)
    }
}

/// Deterministic random numbers (xorshift) so the build is reproducible.
struct Seeded {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
    mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() * Double(range.count)) % range.count }
}

func writeJSON(_ object: Any, _ url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

func load(_ dir: URL, _ name: String) throws -> Canvas {
    guard let canvas = Canvas(url: dir.appendingPathComponent(name)) else {
        throw NSError(domain: "sprites", code: 4, userInfo: [NSLocalizedDescriptionKey: "missing \(name)"])
    }
    return canvas
}

/// Rain tile: streaks, periodic in both directions so a grid of tiles can
/// scroll forever without a seam. Drawn vertical; the renderer shears the
/// moving layer, which slants streaks and motion alike.
func rainTile(width: Int, height: Int, count: Int, length: ClosedRange<Int>, slant: Double, alpha: Double,
              tint: (Double, Double, Double), seed: UInt64) -> Canvas {
    var tile = Canvas(width: width, height: height)
    var random = Seeded(seed)
    for _ in 0..<count {
        let x0 = random.next() * Double(width), y0 = random.next() * Double(height)
        let len = length.lowerBound + random.int(0..<(length.count))
        let a = alpha * (0.6 + 0.4 * random.next())
        for step in 0..<len {
            let x = (Int((x0 + Double(step) * slant).rounded()) % width + width) % width
            let y = (Int(y0) + step) % height
            // Brighter head, fading tail.
            let fade = 0.45 + 0.55 * Double(step) / Double(max(1, len - 1))
            tile.set(x, y, tint.0, tint.1, tint.2, a * fade)
        }
    }
    return tile
}

/// A raindrop on the glass: mostly transparent, a faint lower rim where
/// light gathers and one bright highlight — reads as water, not an icon.
func dropSprite() -> Canvas {
    let rows = [
        ".aa.",
        "abba",
        "abdb",
        "abbc",
        ".cc.",
    ]
    var sprite = Canvas(width: 4, height: rows.count)
    let colours: [Character: (Double, Double, Double, Double)] = [
        "a": (0.80, 0.86, 0.94, 0.16), "b": (0.70, 0.78, 0.88, 0.10),
        "c": (0.90, 0.94, 1.00, 0.42), "d": (1, 1, 1, 0.75),
    ]
    for (y, row) in rows.enumerated() {
        for (x, ch) in row.enumerated() { if let c = colours[ch] { sprite.set(x, y, c.0, c.1, c.2, c.3) } }
    }
    return sprite
}

/// Glow dot (firefly, glint, light): bright centre, dim cross.
func glowSprite(_ colour: (Double, Double, Double)) -> Canvas {
    var sprite = Canvas(width: 3, height: 3)
    sprite.set(1, 1, 1, 1, 0.9, 1)
    for (x, y) in [(0, 1), (2, 1), (1, 0), (1, 2)] { sprite.set(x, y, colour.0, colour.1, colour.2, 0.55) }
    return sprite
}

// MARK: Rain (Parkbank)

func makeRain(pixelized: URL, out: URL) throws {
    let room = try load(pixelized, "Parkbank.png")
    try room.write(out.appendingPathComponent("scene_rain_room.png"))
    try rainTile(width: 320, height: 180, count: 70, length: 5...9, slant: 0, alpha: 0.55, tint: (0.78, 0.84, 0.92), seed: 11)
        .write(out.appendingPathComponent("scene_rain_near.png"))
    try rainTile(width: 320, height: 180, count: 120, length: 3...5, slant: 0, alpha: 0.32, tint: (0.70, 0.78, 0.88), seed: 12)
        .write(out.appendingPathComponent("scene_rain_far.png"))
    try dropSprite().write(out.appendingPathComponent("scene_drop.png"))
    // Ripple frames: a widening pixel ellipse that fades out.
    let frames = 6
    var ripples = Canvas(width: 11 * frames, height: 5)
    for f in 0..<frames {
        let rx = 1.0 + Double(f) * 0.9, ry = max(0.6, rx * 0.38)
        let a = 0.8 * (1 - Double(f) / Double(frames))
        for y in 0..<5 { for x in 0..<11 {
            let dx = (Double(x) - 5) / rx, dy = (Double(y) - 2) / ry
            let d = sqrt(dx * dx + dy * dy)
            if abs(d - 1) < 0.35 { ripples.set(f * 11 + x, y, 0.80, 0.86, 0.92, a) }
        } }
    }
    try ripples.write(out.appendingPathComponent("scene_rain_ripple.png"))
    // Ripple spots: on the puddle (light, bluish water pixels).
    var spots: [[Int]] = []
    var random = Seeded(21)
    var tries = 0
    while spots.count < 9 && tries < 5000 {
        tries += 1
        let x = random.int(100..<312), y = random.int(112..<146)
        let (r, g, b) = room.rgb(x, y)
        if b > 0.45 && b > r + 0.05 && g > 0.4 && spots.allSatisfy({ abs($0[0] - x) > 14 || abs($0[1] - y) > 5 }) { spots.append([x, y]) }
    }
    try writeJSON(["canvas": [320, 180], "ripples": spots, "focus": [0.5, 0.55]], out.appendingPathComponent("scene_rain.json"))
    print("rain: \(spots.count) ripple spots")
}

// MARK: Storm (Barn)

func makeStorm(pixelized: URL, out: URL) throws {
    let room = try load(pixelized, "Barn.png")
    try room.write(out.appendingPathComponent("scene_storm_room.png"))
    try rainTile(width: 320, height: 180, count: 110, length: 6...11, slant: 0, alpha: 0.5, tint: (0.72, 0.78, 0.9), seed: 31)
        .write(out.appendingPathComponent("scene_storm_near.png"))
    try rainTile(width: 320, height: 180, count: 160, length: 3...6, slant: 0, alpha: 0.28, tint: (0.62, 0.7, 0.84), seed: 32)
        .write(out.appendingPathComponent("scene_storm_far.png"))
    // Lightning illumination: the scene's own shapes lit cold-white (added
    // on top during a flash, so clouds and the barn light up, not a flat
    // white sheet).
    var flash = Canvas(width: room.width, height: room.height)
    for y in 0..<room.height { for x in 0..<room.width {
        let l = room.luma(x, y)
        let sky = y < 70 ? 1.0 : max(0.5, 1 - Double(y - 70) / 60)
        let strength = min(1, (0.25 + l * 2.4) * sky)
        flash.set(x, y, 0.78, 0.84, 1.0, (strength * 4).rounded(.down) / 4 * 0.9)
    } }
    try flash.write(out.appendingPathComponent("scene_storm_flash.png"))
    // Three bolt variants: jagged 1-px paths with short forks.
    for variant in 0..<3 {
        var bolt = Canvas(width: 40, height: 80)
        var random = Seeded(UInt64(40 + variant))
        func strike(_ x0: Double, _ y0: Int, _ length: Int, _ main: Bool) {
            var x = x0
            for y in y0..<min(80, y0 + length) {
                x += (random.next() - 0.5) * 2.2
                let xi = max(0, min(39, Int(x.rounded())))
                bolt.set(xi, y, 0.92, 0.95, 1, main ? 1 : 0.7)
                if main, xi + 1 < 40 { bolt.set(xi + 1, y, 0.6, 0.7, 1, 0.35) }
                if main, random.next() < 0.05 { strike(x, y, 10 + random.int(0..<14), false) }
            }
        }
        strike(20, 0, 70 + random.int(0..<10), true)
        try bolt.write(out.appendingPathComponent("scene_storm_bolt\(variant).png"))
    }
    try writeJSON(["canvas": [320, 180], "boltArea": [40, 0, 260, 40], "focus": [0.72, 0.6]], out.appendingPathComponent("scene_storm.json"))
    print("storm: ok")
}

// MARK: Jungle / brook

func makeJungle(pixelized: URL, out: URL) throws {
    let room = try load(pixelized, "Jungle.png")
    try room.write(out.appendingPathComponent("scene_forest_room.png"))
    try glowSprite((0.85, 1.0, 0.45)).write(out.appendingPathComponent("scene_firefly.png"))
    try glowSprite((0.75, 0.88, 1.0)).write(out.appendingPathComponent("scene_glint.png"))
    // Glints: bright bluish river pixels.
    var glints: [[Int]] = []
    var random = Seeded(51)
    var tries = 0
    while glints.count < 14 && tries < 20000 {
        tries += 1
        let x = random.int(100..<260), y = random.int(85..<178)
        let (r, g, b) = room.rgb(x, y)
        if b > 0.38 && b > r + 0.1 && glints.allSatisfy({ abs($0[0] - x) > 6 || abs($0[1] - y) > 6 }) { glints.append([x, y]) }
    }
    // Firefly paths: wandering through the undergrowth and the lower canopy.
    var paths: [[[Int]]] = []
    for _ in 0..<16 {
        var path: [[Int]] = []
        var x = random.int(10..<310), y = random.int(60..<170)
        for _ in 0..<6 {
            path.append([x, y])
            x = max(4, min(316, x + random.int(-40..<41)))
            y = max(50, min(176, y + random.int(-22..<23)))
        }
        paths.append(path)
    }
    try writeJSON(["canvas": [320, 180], "glints": glints, "fireflies": paths, "focus": [0.5, 0.6]],
                  out.appendingPathComponent("scene_forest.json"))
    print("forest: \(glints.count) glints, \(paths.count) fireflies")
}

// MARK: Ocean

func makeOcean(pixelized: URL, out: URL) throws {
    let room = try load(pixelized, "Meer.png")
    try room.write(out.appendingPathComponent("scene_ocean_room.png"))
    // Foam: water pixels that touch the sand (light, unsaturated).
    func isSand(_ x: Int, _ y: Int) -> Bool { let (s, v) = room.sv(x, y); return v > 0.33 && s < 0.32 && y > 90 }
    func isWater(_ x: Int, _ y: Int) -> Bool { let (r, _, b) = room.rgb(x, y); return b > r + 0.06 && room.luma(x, y) < 0.36 && y > 45 }
    var foam = Canvas(width: room.width, height: room.height)
    var foamCount = 0
    for y in 1..<(room.height - 1) { for x in 1..<(room.width - 1) where isWater(x, y) {
        if isSand(x + 1, y) || isSand(x, y + 1) || isSand(x + 1, y + 1) || isSand(x - 1, y + 1) {
            foam.set(x, y, 0.86, 0.9, 0.95, 0.75); foamCount += 1
            if x > 1 { foam.set(x - 1, y, 0.75, 0.82, 0.9, 0.35) }
        }
    } }
    try foam.write(out.appendingPathComponent("scene_ocean_foam.png"))
    try glowSprite((0.85, 0.9, 1.0)).write(out.appendingPathComponent("scene_glint.png"))
    // Moon glitter: along the moon's reflection band.
    var glitter: [[Int]] = []
    var random = Seeded(61)
    for _ in 0..<14 { glitter.append([random.int(146..<178), random.int(44..<52)]) }
    for _ in 0..<8 { glitter.append([random.int(120..<210), random.int(52..<72)]) }
    try writeJSON(["canvas": [320, 180], "glitter": glitter, "focus": [0.5, 0.45]], out.appendingPathComponent("scene_ocean.json"))
    print("ocean: \(foamCount) foam px")
}

// MARK: Cyberpunk

func makeCyberpunk(pixelized: URL, out: URL) throws {
    let room = try load(pixelized, "cyberpunk.png")
    try room.write(out.appendingPathComponent("scene_cyberpunk_room.png"))
    // Neon: saturated bright pixels. "Off" overlays darken them; flicker =
    // briefly showing an overlay. Three groups across the width.
    var groups = (0..<3).map { _ in Canvas(width: room.width, height: room.height) }
    var neonCount = 0
    func isNeon(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < room.width, y < room.height else { return false }
        let (s, v) = room.sv(x, y); return s > 0.5 && v > 0.68
    }
    for y in 0..<room.height { for x in 0..<room.width {
        // Signs are solid areas; haze between the towers only has stray
        // saturated pixels — require at least two neon neighbours.
        guard isNeon(x, y) else { continue }
        let neighbours = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].filter { isNeon($0.0, $0.1) }.count
        guard neighbours >= 2 else { continue }
        let (r, g, b) = room.rgb(x, y)
        groups[min(2, x * 3 / room.width)].set(x, y, r * 0.35, g * 0.3, b * 0.4, 1)
        neonCount += 1
    } }
    for (i, group) in groups.enumerated() { try group.write(out.appendingPathComponent("scene_cyberpunk_neon\(i).png")) }
    // Windows that switch off now and then (one by one at runtime): small
    // bright, low-saturation spots on a dark facade.
    var windows: [[Int]] = []
    var random = Seeded(71)
    for _ in 0..<40000 where windows.count < 60 {
        let x = random.int(1..<(room.width - 1)), y = random.int(10..<150)
        let (s, v) = room.sv(x, y)
        guard v > 0.7, s < 0.4 else { continue }
        let around = (room.sv(x - 1, y).1 + room.sv(x + 1, y).1 + room.sv(x, y - 1).1 + room.sv(x, y + 1).1) / 4
        if around < v - 0.2 { windows.append([x, y]) }
    }
    try glowSprite((0.6, 0.95, 1.0)).write(out.appendingPathComponent("scene_cyberpunk_light.png"))
    try rainTile(width: 320, height: 180, count: 60, length: 4...7, slant: 0, alpha: 0.3, tint: (0.75, 0.7, 0.95), seed: 72)
        .write(out.appendingPathComponent("scene_cyberpunk_rain.png"))
    // Traffic lanes (y) for flying lights, and the bridges.
    try writeJSON(["canvas": [320, 180], "lanes": [[0, 320, 51], [250, 302, 52], [0, 320, 70], [0, 320, 96], [200, 290, 86]],
                   "windows": windows, "focus": [0.5, 0.5]], out.appendingPathComponent("scene_cyberpunk.json"))
    print("cyberpunk: \(neonCount) neon px, \(windows.count) windows")
}

// MARK: Train

func makeTrain(pixelized: URL, out: URL) throws {
    let cabin = try load(pixelized, "zug_green.png")
    try cabin.write(out.appendingPathComponent("scene_train_cabin.png"))
    try load(pixelized, "abend_zug.png").write(out.appendingPathComponent("scene_train_sky.png"))
    try load(pixelized, "ebenegrün.png").write(out.appendingPathComponent("scene_train_far.png"))
    try load(pixelized, "Bahnschiene_grün.png").write(out.appendingPathComponent("scene_train_near.png"))
    var minX = cabin.width, minY = cabin.height, maxX = 0, maxY = 0
    for y in 0..<cabin.height { for x in 0..<cabin.width where cabin.alpha(x, y) == 0 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    try writeJSON(["canvas": [320, 180], "window": [minX, minY, maxX - minX + 1, maxY - minY + 1],
                   "focus": [Double(minX + maxX) / 640, Double(minY + maxY) / 360]], out.appendingPathComponent("scene_train.json"))
    print("train: window \(minX),\(minY) – \(maxX),\(maxY)")
}

// MARK: Brook (river landscape)

/// Flowing water behind the keyed river: ripple streaks in perspective
/// (fine and calm far away, broad near the viewer) drifting towards the
/// viewer. Looping frames, hard palette steps.
func makeWater(pixelized: URL, out: URL) throws {
    let land = try load(pixelized, "fluss_landschaft_grün.png")
    try land.write(out.appendingPathComponent("scene_water_land.png"))
    // River extent: transparent pixels of the keyed landscape.
    var top = land.height
    for y in 0..<land.height { for x in 0..<land.width where land.alpha(x, y) == 0 { top = min(top, y) } }
    let horizon = Double(max(0, top - 2))
    let palette: [(Double, Double, Double)] = [
        (0.30, 0.43, 0.52), (0.38, 0.53, 0.62), (0.47, 0.62, 0.70), (0.62, 0.75, 0.81), (0.88, 0.93, 0.95),
    ]
    let frames = 12
    var sheet = Canvas(width: land.width * frames, height: land.height)
    for frame in 0..<frames {
        let t = Double(frame) / Double(frames)
        for y in Int(horizon)..<land.height {
            let z = (Double(y) - horizon) / (Double(land.height) - horizon) // 0 far … 1 near
            let depth = 1 / (z + 0.08)
            let v = depth * 60 + t * 8
            for x in 0..<land.width {
                guard land.alpha(x, y) == 0 || (y + 1 < land.height && land.alpha(x, y + 1) == 0) else { continue }
                let u = (Double(x) - 160) / depth * 0.9
                let n = noise(u * 0.18, v * 0.5, periodX: 4096, periodY: 4, seed: 7) * 0.7
                    + noise(u * 0.5, v * 1.0, periodX: 4096, periodY: 8, seed: 8) * 0.3
                // Far away the water calms to its middle tone.
                let contrast = 0.35 + 0.65 * z
                let value = 0.5 + (n - 0.5) * contrast * 1.9
                let level = max(0, min(palette.count - 1, Int(value * Double(palette.count))))
                let c = palette[level]
                sheet.set(frame * land.width + x, y, c.0, c.1, c.2, 1)
            }
        }
    }
    try sheet.write(out.appendingPathComponent("scene_water_flow.png"))
    try writeJSON(["canvas": [land.width, land.height], "frames": frames, "focus": [0.5, 0.55]],
                  out.appendingPathComponent("scene_water.json"))
    print("water: river from y \(top), \(frames) frames")
}

// MARK: Library sprites (pixel-art shelf decorations)

typealias RGB = (Double, Double, Double)

/// Darkens the edge pixels of every shape: the classic 1-px pixel-art
/// outline in a darker tone of the shape's own colour.
func outlined(_ c: Canvas) -> Canvas {
    var out = c
    for y in 0..<c.height { for x in 0..<c.width where c.alpha(x, y) > 0 {
        let edge = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains { nx, ny in
            nx < 0 || ny < 0 || nx >= c.width || ny >= c.height || c.alpha(nx, ny) == 0
        }
        if edge { let (r, g, b) = c.rgb(x, y); out.set(x, y, r * 0.5, g * 0.45, b * 0.45, 1) }
    } }
    return out
}

func fillRect(_ c: inout Canvas, _ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ col: RGB) {
    for y in max(0, y0)..<min(c.height, y0 + h) { for x in max(0, x0)..<min(c.width, x0 + w) { c.set(x, y, col.0, col.1, col.2, 1) } }
}

func makeGlobe() -> Canvas {
    var c = Canvas(width: 26, height: 30)
    let brass: RGB = (0.80, 0.62, 0.25), brassLight: RGB = (0.95, 0.80, 0.42)
    let cx = 12.5, cy = 11.0, r = 9.0
    for y in 0..<30 { for x in 0..<26 {
        let dx = Double(x) - cx, dy = Double(y) - cy, d = sqrt(dx * dx + dy * dy)
        if d <= r {
            // Continents from noise; light from the top left.
            let land = noise(Double(x) * 0.28, Double(y) * 0.28, periodX: 64, periodY: 64, seed: 9) > 0.56
            let light = (-dx - dy) / (r * 2) // -1…1
            let base: RGB = land ? (0.80, 0.76, 0.48) : (0.20, 0.42, 0.72)
            let shade = light > 0.25 ? 1.18 : (light < -0.3 ? 0.72 : 1.0)
            c.set(x, y, base.0 * shade, base.1 * shade, base.2 * shade, 1)
        } else if d > r + 0.9 && d <= r + 2.0 && dx > -3 {
            // Meridian ring on the right half.
            c.set(x, y, brass.0, brass.1, brass.2, 1)
        }
    } }
    // Stand: stem and foot.
    fillRect(&c, 12, 22, 2, 4, brass)
    fillRect(&c, 7, 26, 12, 2, brass)
    fillRect(&c, 8, 26, 6, 1, brassLight)
    fillRect(&c, 5, 28, 16, 2, brass)
    return outlined(c)
}

func makePlant() -> Canvas {
    var c = Canvas(width: 28, height: 34)
    let leaf: RGB = (0.30, 0.62, 0.30), leafLight: RGB = (0.48, 0.78, 0.40)
    // Leaves: narrow pointed blades fanning out of the pot, each with its
    // own dark edge (drawn first, slightly wider) so they read as separate.
    let edge: RGB = (0.12, 0.30, 0.16)
    let leaves: [(angle: Double, length: Double)] = [(-1.62, 19), (-1.95, 17), (-1.3, 16), (-2.25, 13), (-1.0, 13), (-2.6, 9), (-0.7, 9)]
    // Back to front, each leaf complete (edge, then fill), so a front leaf's
    // edge stays visible where it overlaps the one behind.
    for (angle, length) in leaves {
        for pass in 0..<2 {
            for step in 0..<Int(length * 4) {
                let t = Double(step) / (length * 4)
                let half = sin(min(1, t * 1.15) * .pi) * 1.5 + (pass == 0 ? 0.8 : 0)
                let px = 14 + cos(angle) * length * t, py = 22 + sin(angle) * length * t
                let nx = -sin(angle), ny = cos(angle)
                var w = -half
                while w <= half {
                    let x = Int((px + nx * w).rounded()), y = Int((py + ny * w).rounded())
                    if x >= 0, y >= 0, x < 28, y < 34 {
                        let col = pass == 0 ? edge : (w > 0.2 ? leafLight : leaf)
                        c.set(x, y, col.0, col.1, col.2, 1)
                    }
                    w += 0.4
                }
            }
        }
    }
    // Pot: terracotta, rim, slight taper.
    let pot: RGB = (0.78, 0.42, 0.26), potLight: RGB = (0.90, 0.56, 0.36)
    fillRect(&c, 6, 21, 16, 3, potLight)
    for y in 24..<33 {
        let inset = (y - 24) / 4
        fillRect(&c, 7 + inset, y, 14 - 2 * inset, 1, pot)
        fillRect(&c, 8 + inset, y, 3, 1, potLight)
    }
    // Outline the pot only — the leaves carry their own edges.
    var result = c
    for y in 21..<34 { for x in 0..<28 where c.alpha(x, y) > 0 {
        let isEdge = [(x - 1, y), (x + 1, y), (x, y + 1)].contains { nx, ny in nx < 0 || nx >= 28 || ny >= 34 || c.alpha(nx, ny) == 0 }
        if isEdge { let (r, g, b) = c.rgb(x, y); result.set(x, y, r * 0.5, g * 0.45, b * 0.45, 1) }
    } }
    return result
}

func makeBookStack() -> Canvas {
    var c = Canvas(width: 36, height: 14)
    let books: [(x: Int, w: Int, col: RGB)] = [(4, 28, (0.20, 0.30, 0.38)), (1, 30, (0.22, 0.42, 0.46)), (3, 31, (0.48, 0.28, 0.18))]
    for (index, book) in books.enumerated() {
        let y = index * 4 + 1
        fillRect(&c, book.x, y, book.w, 4, book.col)
        fillRect(&c, book.x, y, book.w, 1, (book.col.0 * 1.35, book.col.1 * 1.35, book.col.2 * 1.35))
        // Gold title lines on the spine.
        fillRect(&c, book.x + 9, y + 2, 9, 1, (0.92, 0.78, 0.42))
        fillRect(&c, book.x + 2, y + 1, 1, 2, (0.92, 0.78, 0.42))
        fillRect(&c, book.x + book.w - 3, y + 1, 1, 2, (0.92, 0.78, 0.42))
    }
    return outlined(c)
}

func makeBookend() -> Canvas {
    var c = Canvas(width: 10, height: 26)
    let metal: RGB = (0.88, 0.86, 0.80), light: RGB = (0.98, 0.97, 0.93), gold: RGB = (0.80, 0.66, 0.36)
    fillRect(&c, 1, 1, 4, 22, metal)
    fillRect(&c, 2, 1, 1, 21, light)
    fillRect(&c, 1, 22, 9, 3, gold)
    return outlined(c)
}

func makeHourglass() -> Canvas {
    var c = Canvas(width: 14, height: 22)
    let wood: RGB = (0.50, 0.30, 0.16), glass: RGB = (0.78, 0.86, 0.90), sand: RGB = (0.92, 0.78, 0.48)
    fillRect(&c, 0, 0, 14, 2, wood); fillRect(&c, 0, 20, 14, 2, wood)
    fillRect(&c, 1, 2, 1, 18, wood); fillRect(&c, 12, 2, 1, 18, wood)
    for y in 2..<20 {
        let half = y < 11 ? max(1, 5 - (y - 2) / 2) : max(1, 1 + (y - 11) / 2)
        fillRect(&c, 7 - half, y, half * 2, 1, glass)
        if y >= 15 || (y >= 7 && y < 11) { fillRect(&c, 7 - min(half, y >= 15 ? half : 1), y, min(half, y >= 15 ? half : 1) * 2, 1, sand) }
    }
    return outlined(c)
}

func makeCandle() -> Canvas {
    var c = Canvas(width: 10, height: 24)
    fillRect(&c, 3, 6, 4, 14, (0.95, 0.92, 0.82))
    fillRect(&c, 3, 6, 1, 14, (1, 0.98, 0.92))
    fillRect(&c, 1, 20, 8, 3, (0.80, 0.66, 0.36))
    fillRect(&c, 4, 1, 2, 3, (1.0, 0.72, 0.25))
    fillRect(&c, 4, 0, 1, 1, (1.0, 0.92, 0.55))
    fillRect(&c, 4, 4, 1, 2, (0.25, 0.2, 0.18))
    return outlined(c)
}

func makePencil() -> Canvas {
    var c = Canvas(width: 6, height: 22)
    fillRect(&c, 1, 0, 3, 3, (0.95, 0.56, 0.62))   // eraser
    fillRect(&c, 1, 3, 3, 1, (0.75, 0.75, 0.78))   // ferrule
    fillRect(&c, 1, 4, 3, 14, (0.98, 0.78, 0.26))  // body
    fillRect(&c, 2, 4, 1, 14, (1.0, 0.88, 0.45))
    fillRect(&c, 1, 18, 3, 2, (0.92, 0.80, 0.62))  // wood tip
    fillRect(&c, 2, 20, 1, 2, (0.25, 0.22, 0.2))   // lead
    return outlined(c)
}

func makeMug() -> Canvas {
    var c = Canvas(width: 14, height: 12)
    fillRect(&c, 1, 2, 9, 10, (0.30, 0.50, 0.72))
    fillRect(&c, 2, 2, 2, 10, (0.45, 0.65, 0.85))
    fillRect(&c, 10, 4, 3, 1, (0.30, 0.50, 0.72)); fillRect(&c, 12, 4, 1, 5, (0.30, 0.50, 0.72)); fillRect(&c, 10, 8, 3, 1, (0.30, 0.50, 0.72))
    fillRect(&c, 2, 2, 7, 1, (0.35, 0.22, 0.14)) // coffee
    fillRect(&c, 4, 0, 1, 1, (0.85, 0.85, 0.88)); fillRect(&c, 6, 0, 1, 1, (0.85, 0.85, 0.88)) // steam
    return outlined(c)
}

func makeFrame() -> Canvas {
    var c = Canvas(width: 18, height: 22)
    fillRect(&c, 0, 0, 18, 22, (0.62, 0.42, 0.22))
    fillRect(&c, 2, 2, 14, 18, (0.70, 0.84, 0.92))   // sky
    fillRect(&c, 2, 13, 14, 7, (0.42, 0.62, 0.36))   // hill
    fillRect(&c, 5, 10, 6, 3, (0.42, 0.62, 0.36))
    fillRect(&c, 11, 4, 3, 3, (0.98, 0.88, 0.45))    // sun
    return outlined(c)
}

func makeCactus() -> Canvas {
    var c = Canvas(width: 14, height: 22)
    let green: RGB = (0.36, 0.62, 0.36), light: RGB = (0.52, 0.78, 0.48)
    fillRect(&c, 5, 2, 4, 13, green); fillRect(&c, 6, 2, 1, 13, light)
    fillRect(&c, 1, 6, 3, 2, green); fillRect(&c, 1, 3, 2, 4, green)     // left arm
    fillRect(&c, 9, 8, 3, 2, green); fillRect(&c, 10, 5, 2, 4, green)    // right arm
    fillRect(&c, 6, 0, 2, 2, (0.95, 0.55, 0.70))                          // flower
    fillRect(&c, 3, 15, 8, 2, (0.86, 0.52, 0.34)); fillRect(&c, 4, 17, 6, 5, (0.78, 0.42, 0.26))
    return outlined(c)
}

// MARK: Shelf cat

/// A small tabby cat for the shelf, 20×16 px per frame, facing right.
/// Frames: 0–1 sit (tail swish), 2–5 walk, 6–7 sleep (breathing),
/// 8–9 paw at something, 10 held up (dangling).
func makeCat() -> Canvas {
    let fw = 20, fh = 16, frames = 11
    var sheet = Canvas(width: fw * frames, height: fh)
    let fur: RGB = (0.92, 0.60, 0.30), stripe: RGB = (0.74, 0.42, 0.18), light: RGB = (1.0, 0.86, 0.68)
    let ink: RGB = (0.22, 0.14, 0.10), pink: RGB = (0.96, 0.62, 0.66)

    func frame(_ f: Int) -> Canvas {
        var c = Canvas(width: fw, height: fh)
        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ col: RGB) {
            for y in 0..<fh { for x in 0..<fw {
                let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                if dx * dx + dy * dy <= 1 { c.set(x, y, col.0, col.1, col.2, 1) }
            } }
        }
        func px(_ x: Int, _ y: Int, _ col: RGB) { if x >= 0, y >= 0, x < fw, y < fh { c.set(x, y, col.0, col.1, col.2, 1) } }
        if f == 10 {
            // Held by the scruff: body hanging, legs and tail dangling.
            ellipse(10, 9, 3.4, 4.6, fur)
            ellipse(10, 9.8, 1.8, 3.0, light)
            ellipse(10, 3.2, 3.0, 2.6, fur)
            px(8, 0, fur); px(8, 1, fur); px(12, 0, fur); px(12, 1, fur)
            px(8, 1, pink); px(12, 1, pink)
            px(9, 3, ink); px(11, 3, ink); px(10, 4, pink)
            for y in 13...15 { px(8, y, fur); px(12, y, fur) }          // legs
            for (x, y) in [(13, 11), (14, 12), (14, 13), (15, 14), (15, 15)] { px(x, y, stripe) } // tail
            for y in [7, 9] { px(7, y, stripe); px(13, y, stripe) }
            return outlined(c)
        }
        let sleeping = f == 6 || f == 7
        let walking = (2...5).contains(f)
        if sleeping {
            // Curled loaf, head tucked, tail around the front.
            let breathe = f == 7 ? 0.4 : 0
            ellipse(10, 11.5 - breathe / 2, 7.5, 3.6 + breathe, fur)
            ellipse(14.5, 11, 3.2, 2.8, fur)                     // head
            px(13, 8, fur); px(16, 8, fur)                        // ears
            px(13, 11, ink); px(14, 11, ink); px(16, 11, ink)    // closed eyes
            for x in 4...15 { px(x, 14, stripe) }                 // tail wrapped
            for x in [6, 9, 12] { px(x, 9, stripe); px(x, 10, stripe) }
        } else {
            let bodyY = walking ? 9.5 : 10.0
            if walking {
                ellipse(9, bodyY, 6.0, 3.0, fur)                  // body, horizontal
            } else {
                ellipse(9.5, 10.5, 4.6, 4.2, fur)                 // sitting body
                ellipse(10.5, 11.5, 2.2, 2.6, light)              // chest
            }
            let headX = walking ? 15.5 : 13.0, headY = walking ? 6.5 : 5.5
            ellipse(headX, headY, 3.2, 2.9, fur)
            let hx = Int(headX), hy = Int(headY)
            px(hx - 2, hy - 3, fur); px(hx - 2, hy - 2, fur); px(hx + 1, hy - 3, fur); px(hx + 1, hy - 2, fur) // ears
            px(hx - 2, hy - 2, pink); px(hx + 1, hy - 2, pink)
            px(hx - 1, hy, ink); px(hx + 1, hy, ink)              // eyes
            px(hx + 2, hy + 1, pink)                              // nose
            // Stripes on the back.
            for x in [6, 8, 10] { px(x, Int(bodyY) - 2, stripe) }
            // Legs.
            if walking {
                let step = f - 2
                let front = [13, 14, 13, 12][step], back = [5, 4, 5, 6][step]
                for leg in [front, back, front - 2, back + 2] { px(leg, 12, fur); px(leg, 13, fur) }
            } else {
                px(8, 14, fur); px(12, 14, fur); px(9, 14, fur); px(13, 14, fur)
                if f >= 8 {
                    // Raised paw.
                    let lift = f == 9 ? 2 : 1
                    px(15, 11 - lift, fur); px(16, 11 - lift, fur); px(16, 10 - lift, light)
                }
            }
            // Tail: swishes while sitting, straight back while walking.
            let tail: [(Int, Int)]
            switch f {
            case 0, 8, 9: tail = [(5, 13), (4, 12), (3, 11), (2, 10), (2, 9), (3, 8)]
            case 1: tail = [(5, 13), (4, 13), (3, 12), (2, 11), (1, 10), (1, 9)]
            default: tail = [(3, 9), (2, 8), (1, 7), (1, 6), (2, 5)]
            }
            for (x, y) in tail { px(x, y, stripe) }
        }
        return outlined(c)
    }
    for f in 0..<frames {
        let fr = frame(f)
        for y in 0..<fh { for x in 0..<fw where fr.alpha(x, y) > 0 {
            let (r, g, b) = fr.rgb(x, y)
            sheet.set(f * fw + x, y, r, g, b, 1)
        } }
    }
    return sheet
}

func makeShelfSprites(out: URL) throws {
    try makeGlobe().write(out.appendingPathComponent("shelf_globe.png"))
    try makePlant().write(out.appendingPathComponent("shelf_plant.png"))
    try makeBookStack().write(out.appendingPathComponent("shelf_books.png"))
    try makeBookend().write(out.appendingPathComponent("shelf_bookend.png"))
    try makeHourglass().write(out.appendingPathComponent("shelf_hourglass.png"))
    try makeCandle().write(out.appendingPathComponent("shelf_candle.png"))
    try makePencil().write(out.appendingPathComponent("shelf_pencil.png"))
    try makeCat().write(out.appendingPathComponent("shelf_cat.png"))
    try makeMug().write(out.appendingPathComponent("shelf_mug.png"))
    try makeFrame().write(out.appendingPathComponent("shelf_frame.png"))
    try makeCactus().write(out.appendingPathComponent("shelf_cactus.png"))
    print("shelf: 7 sprites")
}

// MARK: Main

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: make_sprites <pixelized-dir> <out-dir>"); exit(1) }
let pixelized = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try makeFire(pixelized: pixelized, out: out)
try makeRain(pixelized: pixelized, out: out)
try makeStorm(pixelized: pixelized, out: out)
try makeJungle(pixelized: pixelized, out: out)
try makeOcean(pixelized: pixelized, out: out)
try makeCyberpunk(pixelized: pixelized, out: out)
try makeTrain(pixelized: pixelized, out: out)
try makeWater(pixelized: pixelized, out: out)
try makeShelfSprites(out: out)
