import AppKit
import CoreGraphics
import Foundation

// MARK: - Pixel Canvas Helper
final class PixelIconRenderer {
    let width: Int
    let height: Int
    var pixels: [UInt32] // 0xAARRGGBB in little-endian or BGRA/RGBA

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt32](repeating: 0, count: width * height)
    }

    func setPixel(x: Int, y: Int, r: Double, g: Double, b: Double, a: Double = 1.0) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let red = UInt32(max(0, min(255, (r * 255).rounded())))
        let green = UInt32(max(0, min(255, (g * 255).rounded())))
        let blue = UInt32(max(0, min(255, (b * 255).rounded())))
        let alpha = UInt32(max(0, min(255, (a * 255).rounded())))
        // RGBA premultiplied in standard 32-bit uint
        pixels[y * width + x] = (red) | (green << 8) | (blue << 16) | (alpha << 24)
    }

    func blendPixel(x: Int, y: Int, r: Double, g: Double, b: Double, a: Double) {
        guard x >= 0, x < width, y >= 0, y < height, a > 0 else { return }
        let idx = y * width + x
        let current = pixels[idx]
        let curR = Double(current & 0xFF) / 255.0
        let curG = Double((current >> 8) & 0xFF) / 255.0
        let curB = Double((current >> 16) & 0xFF) / 255.0
        let curA = Double((current >> 24) & 0xFF) / 255.0

        let outA = a + curA * (1.0 - a)
        guard outA > 0 else { return }
        let outR = (r * a + curR * curA * (1.0 - a)) / outA
        let outG = (g * a + curG * curA * (1.0 - a)) / outA
        let outB = (b * a + curB * curA * (1.0 - a)) / outA

        setPixel(x: x, y: y, r: outR, g: outG, b: outB, a: outA)
    }

    func fillRect(x: Int, y: Int, w: Int, h: Int, r: Double, g: Double, b: Double, a: Double = 1.0) {
        guard w > 0, h > 0 else { return }
        let startX = max(0, x)
        let endX = min(width, x + w)
        let startY = max(0, y)
        let endY = min(height, y + h)
        guard startX < endX, startY < endY else { return }
        for py in startY..<endY {
            for px in startX..<endX {
                blendPixel(x: px, y: py, r: r, g: g, b: b, a: a)
            }
        }
    }
}

// Draw the Cozy Fireplace & Open Book Pixel Art at a native low-res grid,
// then cleanly upscale to 1024x1024 and compose with squircle framing & warm lighting!
func renderCozyIcon() -> NSImage {
    // 1. We create the scene at 128x128 pixel-grid for authentic, rich, hand-crafted pixel art
    let gw = 128
    let gh = 128
    let grid = PixelIconRenderer(width: gw, height: gh)

    // Palette:
    // Room / Bricks
    let wallDark = (0.11, 0.08, 0.12)
    let wallMid = (0.18, 0.12, 0.16)
    let brickDark = (0.24, 0.14, 0.13)
    let brickMid = (0.34, 0.18, 0.16)
    let brickLight = (0.44, 0.23, 0.19)
    let mortar = (0.16, 0.10, 0.11)

    // Wood mantelpiece & floor
    let woodDark = (0.22, 0.12, 0.07)
    let woodLight = (0.52, 0.28, 0.14)
    let woodHighlight = (0.65, 0.36, 0.18)

    // Fire / Hearth
    let hearthBack = (0.07, 0.04, 0.05)
    let emberDark = (0.60, 0.10, 0.04)
    let fireRed = (0.88, 0.22, 0.08)
    let fireOrange = (0.98, 0.52, 0.12)
    let fireYellow = (1.00, 0.85, 0.28)
    let fireCore = (1.00, 0.98, 0.72)

    // Book
    let coverBlue = (0.12, 0.22, 0.38)
    let coverGold = (0.85, 0.68, 0.28)
    let pageParchment = (0.95, 0.90, 0.78)
    let pageShadow = (0.80, 0.72, 0.58)
    let textInk = (0.30, 0.24, 0.20)

    // --- Background Wall (Dark cozy study with brick texture) ---
    for y in 0..<gh {
        for x in 0..<gw {
            let dy = Double(y) / Double(gh)
            let base = (
                wallDark.0 + (wallMid.0 - wallDark.0) * dy,
                wallDark.1 + (wallMid.1 - wallDark.1) * dy,
                wallDark.2 + (wallMid.2 - wallDark.2) * dy
            )
            grid.setPixel(x: x, y: y, r: base.0, g: base.1, b: base.2, a: 1.0)
        }
    }

    // Brick pattern in background
    for row in 0..<18 {
        let by = row * 4 + 2
        let offset = (row % 2 == 0) ? 0 : 5
        // Horizontal mortar
        grid.fillRect(x: 0, y: by, w: gw, h: 1, r: mortar.0, g: mortar.1, b: mortar.2, a: 0.6)
        // Vertical mortars & brick variations
        for col in 0..<14 {
            let bx = col * 10 + offset
            if bx >= 0 && bx < gw {
                grid.fillRect(x: bx, y: by + 1, w: 1, h: 3, r: mortar.0, g: mortar.1, b: mortar.2, a: 0.6)
            }
            // subtle brick tone
            let bVar = Double((col * 7 + row * 13) % 5) * 0.02
            grid.fillRect(x: bx + 1, y: by + 1, w: 9, h: 3, r: brickDark.0 + bVar, g: brickDark.1 + bVar, b: brickDark.2, a: 0.35)
        }
    }

    // --- Fireplace Structure ---
    // Outer Stone Pillars: X from 24 to 104, Y from 28 to 100
    let fpLeft = 24
    let fpRight = 104
    let fpTop = 32
    let fpBottom = 96

    // Stone Frame
    grid.fillRect(x: fpLeft, y: fpTop, w: fpRight - fpLeft, h: fpBottom - fpTop, r: brickMid.0, g: brickMid.1, b: brickMid.2, a: 1.0)

    // Brick texture on fireplace frame
    for r in 0..<16 {
        let by = fpTop + r * 4
        guard by < fpBottom else { break }
        let offset = (r % 2 == 0) ? fpLeft : fpLeft + 4
        grid.fillRect(x: fpLeft, y: by, w: fpRight - fpLeft, h: 1, r: mortar.0, g: mortar.1, b: mortar.2, a: 0.8)
        var bx = offset
        while bx < fpRight {
            grid.fillRect(x: bx, y: by + 1, w: 1, h: 3, r: mortar.0, g: mortar.1, b: mortar.2, a: 0.8)
            let bVar = Double((bx * 3 + r * 5) % 4) * 0.03
            grid.fillRect(x: bx + 1, y: by + 1, w: 7, h: 3, r: brickLight.0 + bVar, g: brickLight.1 + bVar, b: brickLight.2, a: 0.4)
            bx += 8
        }
    }

    // Fireplace Mantelshelf (Wood on top)
    // Top slab
    grid.fillRect(x: fpLeft - 6, y: fpTop - 6, w: (fpRight - fpLeft) + 12, h: 3, r: woodLight.0, g: woodLight.1, b: woodLight.2, a: 1.0)
    grid.fillRect(x: fpLeft - 6, y: fpTop - 6, w: (fpRight - fpLeft) + 12, h: 1, r: woodHighlight.0, g: woodHighlight.1, b: woodHighlight.2, a: 1.0)
    // Mantle base
    grid.fillRect(x: fpLeft - 4, y: fpTop - 3, w: (fpRight - fpLeft) + 8, h: 3, r: woodDark.0, g: woodDark.1, b: woodDark.2, a: 1.0)

    // Items on mantle:
    // Left: Stack of small vintage books
    grid.fillRect(x: fpLeft - 1, y: fpTop - 11, w: 10, h: 2, r: 0.65, g: 0.20, b: 0.20, a: 1.0) // Red book
    grid.fillRect(x: fpLeft, y: fpTop - 9, w: 9, h: 2, r: 0.20, g: 0.45, b: 0.35, a: 1.0) // Green book
    grid.fillRect(x: fpLeft - 2, y: fpTop - 7, w: 11, h: 2, r: 0.22, g: 0.32, b: 0.55, a: 1.0) // Blue book
    // Right: Candle in golden holder
    grid.fillRect(x: fpRight - 10, y: fpTop - 8, w: 6, h: 1, r: 0.85, g: 0.70, b: 0.25, a: 1.0) // base
    grid.fillRect(x: fpRight - 8, y: fpTop - 14, w: 2, h: 6, r: 0.92, g: 0.90, b: 0.82, a: 1.0) // candle wax
    grid.fillRect(x: fpRight - 8, y: fpTop - 16, w: 2, h: 2, r: 1.0, g: 0.8, b: 0.2, a: 1.0) // candle flame
    grid.blendPixel(x: fpRight - 7, y: fpTop - 17, r: 1.0, g: 0.95, b: 0.6, a: 0.8)

    // Hearth Opening (Arched Chimney Hearth)
    let hearthLeft = 40
    let hearthRight = 88
    let hearthTop = 46
    let hearthBottom = 94

    // Dark cavity
    for y in hearthTop..<hearthBottom {
        for x in hearthLeft..<hearthRight {
            // Arch curve at top
            if y < hearthTop + 6 {
                let archProgress = Double(abs(x - 64)) / 24.0
                if archProgress > 0.95 && y < hearthTop + 3 { continue }
                if archProgress > 0.80 && y < hearthTop + 2 { continue }
                if archProgress > 0.60 && y < hearthTop + 1 { continue }
            }
            grid.setPixel(x: x, y: y, r: hearthBack.0, g: hearthBack.1, b: hearthBack.2, a: 1.0)
        }
    }

    // Cast iron frame around hearth
    for x in (hearthLeft - 2)...(hearthRight + 1) {
        grid.setPixel(x: x, y: hearthTop - 1, r: 0.15, g: 0.12, b: 0.14, a: 1.0)
    }
    for y in hearthTop..<hearthBottom {
        grid.fillRect(x: hearthLeft - 2, y: y, w: 2, h: 1, r: 0.15, g: 0.12, b: 0.14, a: 1.0)
        grid.fillRect(x: hearthRight, y: y, w: 2, h: 1, r: 0.15, g: 0.12, b: 0.14, a: 1.0)
    }

    // Firewood Logs & Grate
    // Fire grate (horizontal and vertical black bars)
    grid.fillRect(x: 46, y: 88, w: 36, h: 2, r: 0.12, g: 0.10, b: 0.11, a: 1.0)
    for gx in stride(from: 48, through: 80, by: 6) {
        grid.fillRect(x: gx, y: 86, w: 2, h: 5, r: 0.15, g: 0.13, b: 0.14, a: 1.0)
    }
    // Wooden logs on grate
    grid.fillRect(x: 48, y: 83, w: 32, h: 4, r: 0.28, g: 0.15, b: 0.08, a: 1.0)
    grid.fillRect(x: 52, y: 81, w: 24, h: 3, r: 0.35, g: 0.18, b: 0.10, a: 1.0)
    grid.fillRect(x: 54, y: 84, w: 20, h: 1, r: emberDark.0, g: emberDark.1, b: emberDark.2, a: 0.8) // glowing wood core

    // Glowing Embers
    for ex in 50...78 {
        if (ex % 2 == 0) {
            grid.blendPixel(x: ex, y: 85, r: 1.0, g: 0.3, b: 0.05, a: 0.9)
            grid.blendPixel(x: ex, y: 86, r: 1.0, g: 0.7, b: 0.1, a: 0.9)
        }
    }

    // Fireplace Flames (Pixel Flame tongues reaching upwards)
    // Layer 1: Deep Red Silhouette
    let flameShapes: [(Int, Int, Int, Int)] = [
        (56, 70, 16, 12),
        (52, 73, 24, 9),
        (60, 64, 8, 8),
        (58, 60, 6, 6),
        (62, 57, 4, 5),
        (54, 68, 7, 7),
        (67, 67, 8, 8),
        (51, 75, 6, 6),
        (71, 74, 6, 6)
    ]
    for (fx, fy, fw, fh) in flameShapes {
        grid.fillRect(x: fx, y: fy, w: fw, h: fh, r: fireRed.0, g: fireRed.1, b: fireRed.2, a: 0.95)
    }

    // Layer 2: Vibrant Orange mid-flame
    let midFlames: [(Int, Int, Int, Int)] = [
        (55, 73, 18, 9),
        (58, 66, 12, 8),
        (60, 61, 7, 6),
        (61, 58, 4, 4),
        (56, 70, 6, 5),
        (65, 69, 7, 5)
    ]
    for (fx, fy, fw, fh) in midFlames {
        grid.fillRect(x: fx, y: fy, w: fw, h: fh, r: fireOrange.0, g: fireOrange.1, b: fireOrange.2, a: 0.98)
    }

    // Layer 3: Brilliant Yellow & White hot core
    let brightFlames: [(Int, Int, Int, Int)] = [
        (58, 75, 12, 7),
        (61, 68, 7, 7),
        (62, 63, 4, 6),
        (60, 77, 8, 4)
    ]
    for (fx, fy, fw, fh) in brightFlames {
        grid.fillRect(x: fx, y: fy, w: fw, h: fh, r: fireYellow.0, g: fireYellow.1, b: fireYellow.2, a: 1.0)
    }
    // White core sparks
    grid.fillRect(x: 62, y: 72, w: 4, h: 6, r: fireCore.0, g: fireCore.1, b: fireCore.2, a: 1.0)
    grid.fillRect(x: 63, y: 66, w: 3, h: 4, r: fireCore.0, g: fireCore.1, b: fireCore.2, a: 1.0)

    // Sparks / Embers drifting up
    let sparks = [(61, 52), (64, 49), (58, 54), (66, 44), (60, 42), (63, 38)]
    for (sx, sy) in sparks {
        grid.setPixel(x: sx, y: sy, r: 1.0, g: 0.85, b: 0.3, a: 0.9)
    }

    // Radial Fire Glow onto hearth and frame
    for y in (hearthTop - 6)...min(gh - 1, hearthBottom + 12) {
        for x in (hearthLeft - 10)...(hearthRight + 10) {
            let dx = Double(x - 64)
            let dy = Double(y - 74)
            let dist = sqrt(dx * dx + dy * dy)
            if dist < 42 {
                let intensity = (1.0 - dist / 42.0) * 0.35
                grid.blendPixel(x: x, y: y, r: fireOrange.0, g: fireOrange.1 * 0.7, b: 0.05, a: intensity)
            }
        }
    }

    // Wooden Hearth Base / Room Floor
    grid.fillRect(x: 0, y: fpBottom, w: gw, h: gh - fpBottom, r: woodDark.0, g: woodDark.1, b: woodDark.2, a: 1.0)
    // Floor planks
    for py in fpBottom..<gh {
        if py % 7 == 0 {
            grid.fillRect(x: 0, y: py, w: gw, h: 1, r: 0.12, g: 0.06, b: 0.03, a: 0.8) // plank gap
        }
    }
    // Hearthstone platform in front of fireplace
    grid.fillRect(x: 28, y: fpBottom - 2, w: 72, h: 6, r: 0.28, g: 0.20, b: 0.18, a: 1.0)
    grid.fillRect(x: 28, y: fpBottom - 2, w: 72, h: 1, r: 0.45, g: 0.32, b: 0.28, a: 1.0) // stone edge highlight

    // --- Foreground: The Majestic Open Book ---
    // Placed proudly right in front of the warm fireplace glow!
    // Center of book: X = 64, Y = 104. Width = 56, Height = 22
    let bookX = 36
    let bookW = 56
    let bookY = 96
    let bookH = 22

    // 1. Soft shadow cast by the book onto the floor
    for sy in (bookY + bookH - 2)...(bookY + bookH + 4) {
        for sx in (bookX - 4)...(bookX + bookW + 4) {
            grid.blendPixel(x: sx, y: sy, r: 0.02, g: 0.01, b: 0.02, a: 0.6)
        }
    }

    // 2. Leather Cover Bottom & Corners (Hardcover Binding)
    // Deep royal blue & gold trim
    grid.fillRect(x: bookX - 2, y: bookY + 2, w: bookW + 4, h: bookH - 1, r: coverBlue.0, g: coverBlue.1, b: coverBlue.2, a: 1.0)
    // Gold corner protectors
    grid.fillRect(x: bookX - 2, y: bookY + bookH - 2, w: 4, h: 3, r: coverGold.0, g: coverGold.1, b: coverGold.2, a: 1.0)
    grid.fillRect(x: bookX + bookW - 2, y: bookY + bookH - 2, w: 4, h: 3, r: coverGold.0, g: coverGold.1, b: coverGold.2, a: 1.0)

    // 3. Curved Open Pages
    // Left Page (X from 38 to 63), Right Page (X from 65 to 90)
    // Center Spine: X = 64
    for px in bookX...(bookX + bookW) {
        let isSpine = px == 63 || px == 64 || px == 65
        let distFromSpine = abs(Double(px - 64))

        // Page curve elevation (arches slightly up, dips into center gutter)
        let curveY = Int((sin((distFromSpine / 28.0) * .pi * 0.5) * 3.5).rounded())
        let topY = bookY + 5 - curveY
        let botY = bookY + bookH - 3

        if isSpine {
            // Deep center gutter shadow
            grid.fillRect(x: px, y: topY + 2, w: 1, h: botY - topY - 1, r: pageShadow.0 * 0.7, g: pageShadow.1 * 0.7, b: pageShadow.2 * 0.7, a: 1.0)
        } else {
            // Parchment surface
            for py in topY...botY {
                let warmGlow = max(0.0, 1.0 - Double(py - topY) / 12.0) * 0.2
                let r = min(1.0, pageParchment.0 + warmGlow)
                let g = min(1.0, pageParchment.1 + warmGlow * 0.7)
                let b = pageParchment.2
                grid.setPixel(x: px, y: py, r: r, g: g, b: b, a: 1.0)
            }
            // Page top edge highlight from the warm firelight directly behind it!
            grid.blendPixel(x: px, y: topY, r: 1.0, g: 0.92, b: 0.65, a: 0.95)
            // Page side paper stack thickness
            grid.fillRect(x: px, y: botY, w: 1, h: 2, r: pageShadow.0, g: pageShadow.1, b: pageShadow.2, a: 1.0)
        }
    }

    // 4. Delicate Text Lines on the Open Pages
    // Left Page lines
    for line in 0..<5 {
        let ly = bookY + 8 + line * 2
        for tx in 41...60 {
            // Little paragraph gaps and word spacing
            if (tx + line * 3) % 5 != 0 {
                grid.blendPixel(x: tx, y: ly, r: textInk.0, g: textInk.1, b: textInk.2, a: 0.65)
            }
        }
    }
    // Right Page lines
    for line in 0..<5 {
        let ly = bookY + 8 + line * 2
        for tx in 68...87 {
            if (tx + line * 7) % 6 != 0 {
                grid.blendPixel(x: tx, y: ly, r: textInk.0, g: textInk.1, b: textInk.2, a: 0.65)
            }
        }
    }

    // 5. Red Silk Bookmark Ribbon hanging out at the bottom
    let ribbonRed = (0.85, 0.15, 0.18)
    grid.fillRect(x: 63, y: bookY + 12, w: 2, h: 9, r: ribbonRed.0, g: ribbonRed.1, b: ribbonRed.2, a: 1.0)
    grid.fillRect(x: 64, y: bookY + 21, w: 2, h: 3, r: ribbonRed.0, g: ribbonRed.1, b: ribbonRed.2, a: 1.0)
    // Golden tip on ribbon
    grid.fillRect(x: 64, y: bookY + 23, w: 2, h: 1, r: coverGold.0, g: coverGold.1, b: coverGold.2, a: 1.0)

    // --- Convert 128x128 Pixel Canvas into CGImage ---
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    var rawBytes = grid.pixels
    guard let provider = CGDataProvider(data: Data(bytes: &rawBytes, count: gw * gh * 4) as CFData),
          let pixelCGImage = CGImage(
            width: gw,
            height: gh,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: gw * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false, // PRESERVE CRISP PIXEL ART!
            intent: .defaultIntent
          ) else {
        fatalError("Failed to build pixel CGImage")
    }

    // --- Master 1024x1024 macOS Squircle Composition ---
    let masterSize: CGFloat = 1024
    let finalImage = NSImage(size: NSSize(width: masterSize, height: masterSize))
    finalImage.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        fatalError("No CGContext")
    }

    // macOS Icon Dimensions
    // Canvas: 1024x1024
    // Squircle: 824x824, centered at (100, 100)
    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 185

    // 1. Soft macOS Drop Shadow
    ctx.saveGState()
    let shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 32, color: shadowColor)
    let shadowPath = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                                  xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.setFill()
    shadowPath.fill()
    ctx.restoreGState()

    // 2. Clip to Squircle Path
    ctx.saveGState()
    let clipPath = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                                xRadius: cornerRadius, yRadius: cornerRadius)
    clipPath.addClip()

    // 3. Draw Pixel Art scaled cleanly with nearest-neighbor interpolation
    ctx.interpolationQuality = .none
    ctx.draw(pixelCGImage, in: iconRect)

    // 4. Subtle Inner Rim Highlight & Vignette
    // Top highlight rim
    ctx.interpolationQuality = .high
    let rimPath = NSBezierPath(roundedRect: NSRect(x: 101, y: 101, width: 822, height: 822),
                               xRadius: cornerRadius - 1, yRadius: cornerRadius - 1)
    rimPath.lineWidth = 2.0
    NSColor.white.withAlphaComponent(0.18).setStroke()
    rimPath.stroke()

    // Soft warm ambient vignette around the outer edges
    let glowGradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.1, alpha: 0.08),
        NSColor.clear,
        NSColor.black.withAlphaComponent(0.35)
    ], atLocations: [0.0, 0.65, 1.0], colorSpace: .sRGB)
    glowGradient?.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824), relativeCenterPosition: NSPoint(x: 0, y: -0.1))

    ctx.restoreGState()
    finalImage.unlockFocus()

    return finalImage
}

// MARK: - Generation & Downsampling
let master = renderCozyIcon()

guard let masterTiff = master.tiffRepresentation,
      let masterRep = NSBitmapImageRep(data: masterTiff),
      let masterPng = masterRep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode master PNG")
}

let appIconDir = "AudiobookForge/Resources/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: appIconDir, withIntermediateDirectories: true)

// Target sizes required by macOS AppIcon
let sizes: [(String, Int)] = [
    ("icon_1024.png", 1024),
    ("icon_512.png", 512),
    ("icon_256.png", 256),
    ("icon_128.png", 128),
    ("icon_64.png", 64),
    ("icon_32.png", 32),
    ("icon_16.png", 16)
]

for (filename, targetPx) in sizes {
    let targetSize = NSSize(width: targetPx, height: targetPx)
    let resized = NSImage(size: targetSize)
    resized.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(origin: .zero, size: targetSize),
                from: NSRect(origin: .zero, size: master.size),
                operation: .sourceOver,
                fraction: 1.0)
    resized.unlockFocus()

    if let tiff = resized.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        let destURL = URL(fileURLWithPath: "\(appIconDir)/\(filename)")
        try png.write(to: destURL)
        print("Generated \(filename) (\(targetPx)x\(targetPx))")
    }
}

// Also write icon_1024.png to root/build if invoked standalone
let outputArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try masterPng.write(to: URL(fileURLWithPath: outputArg))
print("Successfully generated Cozy App Icon in all resolutions!")
