import SwiftUI
import AppKit
import QuartzCore
import ImageIO

/// Pixel-art ambient scenes (v3.2): a static 320×180 background with a few
/// animated elements, built from Core Animation layers.
///
/// Everything that moves is a Core Animation animation (sprite frames via
/// `contentsRect`, flicker via `opacity`, paths via `position`, particles
/// via `CAEmitterLayer`), so it runs in the system's render server — the app
/// does no per-frame work at all.
///
/// Two views:
/// - `PixelSceneView` — the scene itself, opaque, behind the whole UI.
/// - `PixelSceneGlow` — what falls onto the UI (firelight, drops on the
///   glass, lightning, fireflies, neon), above it, never hit-testable.
///
/// Assets: `scripts/build_scenes.sh` → Resources/Scenes/scene_<scene>_*.
enum PixelSceneSupport {
    /// One shared start time so scene and overlay animations stay in step
    /// even though they live in different views.
    static let epoch = CACurrentMediaTime()

    nonisolated(unsafe) private static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 64
        return c
    }()

    static func image(_ name: String) -> CGImage? {
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Scene layout written by the sprite generator (points in canvas
    /// pixels, y measured from the top like the source images).
    struct Layout: Decodable {
        var canvas: [Int]
        var focus: [Double]?
        var opening: [Int]?
        var frames: Int?
        var lightCenter: [Double]?
        var ripples: [[Int]]?
        var boltArea: [Int]?
        var glints: [[Int]]?
        var fireflies: [[[Int]]]?
        var glitter: [[Int]]?
        var lanes: [[Int]]?
        var windows: [[Int]]?
        var window: [Int]?
    }

    static func layout(_ name: String) -> Layout? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Layout.self, from: data)
    }

    /// Asset prefix per scene (Resources/Scenes/scene_<prefix>_*).
    static func assetName(_ scene: AmbientSound) -> String { scene.rawValue }

    /// Deterministic random numbers: the same scene always looks the same.
    struct Random {
        var state: UInt64
        init(_ seed: Int) { state = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 0x9E37_79B9) | 1 }
        mutating func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1_000_000) / 1_000_000
        }
        mutating func range(_ lower: Double, _ upper: Double) -> Double { lower + (upper - lower) * next() }
    }

    /// Irregular flicker of `opacity` between `low` and `high`; seamless loop.
    static func flicker(duration: CFTimeInterval, low: Float, high: Float, seed: Int, steps: Int = 14) -> CAKeyframeAnimation {
        var random = Random(seed)
        var values: [Float] = (0..<steps).map { _ in low + (high - low) * Float(random.next()) }
        values.append(values[0])
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.beginTime = epoch
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Mostly `rest`, with short random `blip` moments — neon dropouts,
    /// windows switching off, glints catching light.
    static func blips(duration: CFTimeInterval, rest: Float, blip: Float, count: Int, length: Double, seed: Int,
                      discrete: Bool = true) -> CAKeyframeAnimation {
        var random = Random(seed)
        var times: [Double] = [0], values: [Float] = [rest]
        let starts = (0..<count).map { _ in random.range(0.02, 0.92) }.sorted()
        var last = 0.0
        for start in starts where start > last + length / duration + 0.01 {
            let end = min(0.99, start + length / duration * random.range(0.5, 1.5))
            times += [start, end]; values += [blip, rest]
            last = end
        }
        times.append(1); values.append(rest)
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0) }
        animation.calculationMode = discrete ? .discrete : .linear
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.beginTime = epoch + random.range(0, duration)
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Sleep timer: over the last ten minutes before `end` the layer fades
    /// to a glow (the fire burns down). Runs in the render server.
    static func applyBurnDown(to layer: CALayer, end: Date?, from opacity: Float) {
        layer.removeAnimation(forKey: "burnDown")
        guard let end else { return }
        let remaining = end.timeIntervalSinceNow
        guard remaining > 0 else { layer.opacity = 0.08; return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 0.08
        fade.beginTime = CACurrentMediaTime() + max(0, remaining - 600)
        fade.duration = min(600, remaining)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "burnDown")
    }

    /// Lightning: a double flash, then afterglow.
    static func lightningFlash() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 0.2, 0.85, 0.3, 0]
        animation.keyTimes = [0, 0.05, 0.14, 0.22, 0.45, 1]
        animation.duration = 1.1
        animation.isRemovedOnCompletion = true
        return animation
    }

    /// One white pixel; tinted per particle.
    static let pixel: CGImage? = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context?.makeImage()
    }()
}

// MARK: - Scene (behind the UI)

struct PixelSceneView: NSViewRepresentable {
    let scene: AmbientSound
    let intensity: Double
    let animated: Bool
    /// How far the content area's centre sits right of the window centre
    /// (half the sidebar width): the scene's focus goes there, not under
    /// the sidebar.
    var contentOffsetX: CGFloat = 0
    var lastFlash: Date? = nil
    var burnDownEnd: Date? = nil

    func makeNSView(context: Context) -> PixelSceneNSView { PixelSceneNSView() }

    func updateNSView(_ view: PixelSceneNSView, context: Context) {
        view.configure(scene: scene, intensity: intensity, animated: animated, contentOffsetX: contentOffsetX, lastFlash: lastFlash)
        view.setBurnDown(burnDownEnd)
    }
}

final class PixelSceneNSView: NSView {
    /// All scene layers live in canvas coordinates (320×180, origin bottom
    /// left); the canvas is scaled to fill the window without smoothing.
    private let canvas = CALayer()
    /// Effects whose strength follows the intensity slider.
    private let effects = CALayer()
    private var built: (scene: AmbientSound, animated: Bool)?
    private var canvasSize = CGSize(width: 320, height: 180)
    /// Point of the image that stays visible when the window crops it.
    private var focus = CGPoint(x: 0.5, y: 0.5)
    private var contentOffsetX: CGFloat = 0
    private var lastFlash: Date?
    private var flashLayers: [CALayer] = []
    private var bolts: [CALayer] = []
    private var boltArea = CGRect(x: 40, y: 0, width: 260, height: 40)
    private var flashCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        canvas.anchorPoint = .zero
        canvas.masksToBounds = true
        layer?.addSublayer(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(scene: AmbientSound, intensity: Double, animated: Bool, contentOffsetX: CGFloat, lastFlash: Date?) {
        if built?.scene != scene || built?.animated != animated {
            build(scene: scene, animated: animated)
        }
        if self.contentOffsetX != contentOffsetX {
            self.contentOffsetX = contentOffsetX
            needsLayout = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effects.opacity = Float(0.35 + 0.65 * intensity)
        CATransaction.commit()
        if lastFlash != self.lastFlash {
            let isNew = self.lastFlash != nil || (lastFlash.map { Date().timeIntervalSince($0) < 2 } ?? false)
            self.lastFlash = lastFlash
            if isNew, lastFlash != nil, animated { flash() }
        }
    }

    private var burnDownEnd: Date?

    func setBurnDown(_ end: Date?) {
        guard end != burnDownEnd else { return }
        burnDownEnd = end
        PixelSceneSupport.applyBurnDown(to: effects, end: end, from: effects.opacity)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Fill the window; zoom a little further if that's what it takes to
        // put the focus in the middle of the content area (right of the
        // sidebar) instead of the middle of the window.
        let scale = max(bounds.width / canvasSize.width, bounds.height / canvasSize.height,
                        (bounds.width + 2 * contentOffsetX) / canvasSize.width)
        let scaled = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        let targetX = bounds.width / 2 + contentOffsetX
        let x = min(0, max(bounds.width - scaled.width, targetX - scaled.width * focus.x))
        let y = min(0, max(bounds.height - scaled.height, bounds.height / 2 - scaled.height * (1 - focus.y)))
        canvas.bounds = CGRect(origin: .zero, size: canvasSize)
        canvas.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        canvas.position = CGPoint(x: x, y: y)
        CATransaction.commit()
    }

    private func build(scene: AmbientSound, animated: Bool) {
        built = (scene, animated)
        canvas.sublayers?.forEach { $0.removeFromSuperlayer() }
        effects.sublayers?.forEach { $0.removeFromSuperlayer() }
        flashLayers = []; bolts = []
        let name = PixelSceneSupport.assetName(scene)
        guard let layout = PixelSceneSupport.layout("scene_\(name)") else { return }
        canvasSize = CGSize(width: layout.canvas[0], height: layout.canvas[1])
        if let f = layout.focus ?? layout.lightCenter.map({ [$0[0] / Double(layout.canvas[0]), $0[1] / Double(layout.canvas[1])] }) {
            focus = CGPoint(x: f[0], y: f[1])
        }
        effects.frame = CGRect(origin: .zero, size: canvasSize)
        switch scene {
        case .fire: buildFire(layout, animated: animated)
        case .rain: buildRain(layout, animated: animated)
        case .storm: buildStorm(layout, animated: animated)
        case .forest: buildForest(layout, animated: animated)
        case .water: buildWater(layout, animated: animated)
        case .ocean: buildOcean(layout, animated: animated)
        case .cyberpunk: buildCyberpunk(layout, animated: animated)
        case .train: buildTrain(layout, animated: animated)
        }
        canvas.addSublayer(effects)
        needsLayout = true
    }

    // MARK: Layer helpers

    /// Converts a top-based canvas y into Core Animation's bottom-based y.
    private func flipY(_ y: Double, height: Double = 0) -> Double { Double(canvasSize.height) - y - height }

    /// Image layer in canvas coordinates (y from the TOP), crisp when scaled.
    private func imageLayer(_ name: String, x: Double = 0, y: Double = 0, width: Double? = nil, height: Double? = nil) -> CALayer {
        let layer = CALayer()
        let image = PixelSceneSupport.image(name)
        layer.contents = image
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        let w = width ?? Double(image?.width ?? 0), h = height ?? Double(image?.height ?? 0)
        layer.frame = CGRect(x: x, y: flipY(y, height: h), width: w, height: h)
        return layer
    }

    /// Endless rain: a periodic tile scrolling down, sheared so streaks and
    /// motion lean with the wind (`lean` = canvas px sideways per px down).
    private func rain(_ name: String, period: CFTimeInterval, lean: Double, opacity: Float, animated: Bool) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: canvasSize)
        var shear = CATransform3DIdentity
        shear.m21 = CGFloat(lean)
        container.sublayerTransform = shear
        let grid = CALayer()
        grid.anchorPoint = .zero
        grid.bounds = CGRect(x: 0, y: 0, width: canvasSize.width * 3, height: canvasSize.height * 2)
        grid.position = CGPoint(x: -canvasSize.width, y: 0)
        for column in 0..<3 {
            for row in 0..<2 {
                let tile = CALayer()
                tile.contents = PixelSceneSupport.image(name)
                tile.magnificationFilter = .nearest
                tile.frame = CGRect(x: Double(column) * canvasSize.width, y: Double(row) * canvasSize.height,
                                    width: canvasSize.width, height: canvasSize.height)
                grid.addSublayer(tile)
            }
        }
        if animated {
            let fall = CABasicAnimation(keyPath: "position.y")
            fall.fromValue = 0
            fall.toValue = -canvasSize.height
            fall.duration = period
            fall.repeatCount = .infinity
            fall.isRemovedOnCompletion = false
            grid.add(fall, forKey: "fall")
        }
        container.addSublayer(grid)
        container.opacity = opacity
        return container
    }

    /// Horizontal parallax: the layer image, alternately mirrored so any
    /// picture tiles seamlessly, sliding left forever.
    private func parallax(_ name: String, period: CFTimeInterval, animated: Bool) -> CALayer {
        let strip = CALayer()
        strip.anchorPoint = .zero
        strip.bounds = CGRect(x: 0, y: 0, width: canvasSize.width * 3, height: canvasSize.height)
        strip.position = .zero
        for index in 0..<3 {
            let tile = CALayer()
            tile.contents = PixelSceneSupport.image(name)
            tile.magnificationFilter = .nearest
            tile.bounds = CGRect(origin: .zero, size: canvasSize)
            tile.position = CGPoint(x: (Double(index) + 0.5) * canvasSize.width, y: canvasSize.height / 2)
            if index % 2 == 1 { tile.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1)) }
            strip.addSublayer(tile)
        }
        if animated {
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = 0
            slide.toValue = -canvasSize.width * 2
            slide.duration = period
            slide.repeatCount = .infinity
            slide.isRemovedOnCompletion = false
            strip.add(slide, forKey: "slide")
        }
        return strip
    }

    /// A small sprite centred on a canvas pixel.
    private func sprite(_ name: String, at point: [Int]) -> CALayer {
        let image = PixelSceneSupport.image(name)
        let w = Double(image?.width ?? 3), h = Double(image?.height ?? 3)
        return imageLayer(name, x: Double(point[0]) - floor(w / 2), y: Double(point[1]) - floor(h / 2), width: w, height: h)
    }

    // MARK: Fire

    private func buildFire(_ layout: PixelSceneSupport.Layout, animated: Bool) {
        guard let opening = layout.opening?.map(Double.init), let frameCount = layout.frames else { return }
        // 1. The room (logs and grate included).
        canvas.addSublayer(imageLayer("scene_fire_room"))
        // 2. Flames: sprite sheet, one frame at a time (10 fps, discrete).
        let flames = imageLayer("scene_fire_flames", x: opening[0], y: opening[1], width: opening[2], height: opening[3])
        let frameWidth = 1.0 / Double(frameCount)
        flames.contentsRect = CGRect(x: 0, y: 0, width: frameWidth, height: 1)
        if animated {
            let frames = CAKeyframeAnimation(keyPath: "contentsRect")
            frames.values = (0..<frameCount).map { NSValue(rect: NSRect(x: Double($0) * frameWidth, y: 0, width: frameWidth, height: 1)) }
            frames.calculationMode = .discrete
            frames.duration = Double(frameCount) / 10
            frames.repeatCount = .infinity
            frames.isRemovedOnCompletion = false
            flames.add(frames, forKey: "frames")
        }
        canvas.addSublayer(flames)
        // 3. The room again with the opening cut out: clips the flames.
        canvas.addSublayer(imageLayer("scene_fire_front"))
        // 4. Firelight on stones, mantel and rug — added, flickering.
        for (index, duration) in [3.1, 4.7].enumerated() {
            let light = imageLayer("scene_fire_light")
            light.compositingFilter = CIFilter(name: "CIAdditionCompositing")
            light.opacity = 0.7
            if animated { light.add(PixelSceneSupport.flicker(duration: duration, low: 0.45, high: 0.95, seed: index + 1), forKey: "flicker") }
            effects.addSublayer(light)
        }
        // 5. A few sparks rising out of the fire.
        if animated {
            let sparks = CAEmitterLayer()
            sparks.frame = CGRect(origin: .zero, size: canvasSize)
            sparks.emitterShape = .line
            sparks.emitterPosition = CGPoint(x: opening[0] + opening[2] / 2, y: flipY(opening[1] + opening[3] * 0.55))
            sparks.emitterSize = CGSize(width: opening[2] * 0.5, height: 1)
            let cell = CAEmitterCell()
            cell.contents = PixelSceneSupport.pixel
            cell.magnificationFilter = CALayerContentsFilter.nearest.rawValue
            cell.birthRate = 2.5
            cell.lifetime = 2.2
            cell.lifetimeRange = 0.8
            cell.velocity = 14
            cell.velocityRange = 6
            cell.emissionLongitude = .pi / 2
            cell.emissionRange = 0.5
            cell.yAcceleration = 2
            cell.color = CGColor(red: 1, green: 0.72, blue: 0.3, alpha: 1)
            cell.alphaSpeed = -0.45
            cell.greenSpeed = -0.25
            sparks.emitterCells = [cell]
            effects.addSublayer(sparks)
        }
    }

    // MARK: Rain (park bench)

    private func buildRain(_ layout: PixelSceneSupport.Layout, animated: Bool) {
        canvas.addSublayer(imageLayer("scene_rain_room"))
        // Ripples on the puddle: each spot plays the ring once, then rests
        // for a random while.
        if animated {
            var random = PixelSceneSupport.Random(5)
            for (index, spot) in (layout.ripples ?? []).enumerated() {
                let ripple = imageLayer("scene_rain_ripple", x: Double(spot[0] - 5), y: Double(spot[1] - 2), width: 11, height: 5)
                let frameWidth = 1.0 / 6
                ripple.contentsRect = CGRect(x: 0, y: 0, width: frameWidth, height: 1)
                ripple.opacity = 0
                let total = random.range(1.3, 3.4), play = 0.6
                let frames = CAKeyframeAnimation(keyPath: "contentsRect")
                frames.values = (0..<6).map { NSValue(rect: NSRect(x: Double($0) * frameWidth, y: 0, width: frameWidth, height: 1)) }
                frames.calculationMode = .discrete
                frames.duration = play
                let visible = CAKeyframeAnimation(keyPath: "opacity")
                visible.values = [1, 0, 0]
                visible.keyTimes = [0, NSNumber(value: play / total), 1]
                visible.calculationMode = .discrete
                visible.duration = total
                let group = CAAnimationGroup()
                group.animations = [frames, visible]
                group.duration = total
                group.repeatCount = .infinity
                group.beginTime = PixelSceneSupport.epoch + Double(index) * 0.37
                group.isRemovedOnCompletion = false
                ripple.add(group, forKey: "ripple")
                effects.addSublayer(ripple)
            }
        }
        effects.addSublayer(rain("scene_rain_far", period: 1.6, lean: 0.18, opacity: 0.9, animated: animated))
        effects.addSublayer(rain("scene_rain_near", period: 0.75, lean: 0.18, opacity: 1, animated: animated))
    }

    // MARK: Storm (barn)

    private func buildStorm(_ layout: PixelSceneSupport.Layout, animated: Bool) {
        canvas.addSublayer(imageLayer("scene_storm_room"))
        if let area = layout.boltArea { boltArea = CGRect(x: area[0], y: area[1], width: area[2], height: area[3]) }
        // Bolts and the scene lit by them — hidden until a flash.
        for variant in 0..<3 {
            let bolt = imageLayer("scene_storm_bolt\(variant)", x: 0, y: 0, width: 40, height: 80)
            bolt.opacity = 0
            canvas.addSublayer(bolt)
            bolts.append(bolt)
        }
        let lit = imageLayer("scene_storm_flash")
        lit.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        lit.opacity = 0
        canvas.addSublayer(lit)
        flashLayers = [lit]
        effects.addSublayer(rain("scene_storm_far", period: 1.1, lean: 0.45, opacity: 0.9, animated: animated))
        effects.addSublayer(rain("scene_storm_near", period: 0.5, lean: 0.45, opacity: 1, animated: animated))
    }

    private func flash() {
        guard !flashLayers.isEmpty else { return }
        flashCount += 1
        let animation = PixelSceneSupport.lightningFlash()
        for layer in flashLayers { layer.add(animation, forKey: "flash") }
        guard !bolts.isEmpty else { return }
        var random = PixelSceneSupport.Random(flashCount)
        let bolt = bolts[flashCount % bolts.count]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let x = boltArea.minX + random.range(0, boltArea.width)
        bolt.frame = CGRect(x: x, y: flipY(boltArea.minY + random.range(0, boltArea.height), height: 80), width: 40, height: 80)
        CATransaction.commit()
        bolt.add(animation, forKey: "flash")
    }

    // MARK: Jungle

    private func buildForest(_ layout: PixelSceneSupport.Layout, animated: Bool) {
        canvas.addSublayer(imageLayer("scene_forest_room"))
        guard animated else { return }
        // Light catching the water.
        for (index, point) in (layout.glints ?? []).enumerated() {
            let glint = sprite("scene_glint", at: point)
            glint.opacity = 0
            glint.add(PixelSceneSupport.blips(duration: 3.5 + Double(index % 5) * 0.9, rest: 0, blip: 0.9, count: 2,
                                              length: 0.35, seed: 100 + index, discrete: false), forKey: "glint")
            effects.addSublayer(glint)
        }
        for (index, path) in (layout.fireflies ?? []).enumerated() {
            let fly = sprite("scene_firefly", at: path[0])
            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = path.map { NSValue(point: NSPoint(x: Double($0[0]), y: flipY(Double($0[1])))) }
            move.calculationMode = .cubicPaced
            move.duration = 22 + Double(index % 6) * 3
            move.autoreverses = true
            move.repeatCount = .infinity
            move.beginTime = PixelSceneSupport.epoch - Double(index) * 2.3
            move.isRemovedOnCompletion = false
            fly.add(move, forKey: "move")
            fly.opacity = 0
            fly.add(PixelSceneSupport.blips(duration: 4 + Double(index % 4), rest: 0.08, blip: 1, count: 2, length: 0.9,
                                            seed: 200 + index, discrete: false), forKey: "glow")
            effects.addSublayer(fly)
        }
    }

    // MARK: Brook (river landscape)

    private func buildWater(_ layout: PixelSceneSupport.Layout, animated: Bool) {
        // Flowing water first, the landscape with the cut-out river on top.
        let frameCount = layout.frames ?? 12
        let flow = imageLayer("scene_water_flow", width: Double(canvasSize.width), height: Double(canvasSize.height))
        let frameWidth = 1.0 / Double(frameCount)
        flow.contentsRect = CGRect(x: 0, y: 0, width: frameWidth, height: 1)
        if animated {
            let frames = CAKeyframeAnimation(keyPath: "contentsRect")
            frames.values = (0..<frameCount).map { NSValue(rect: NSRect(x: Double($0) * frameWidth, y: 0, width: frameWidth, height: 1)) }
            frames.calculationMode = .discrete
            frames.duration = Double(frameCount) / 8
            frames.repeatCount = .infinity
            frames.isRemovedOnCompletion = false
            flow.add(frames, forKey: "flow")
        }
        canvas.addSublayer(flow)
        canvas.addSublayer(imageLayer("scene_water_land"))
    }

    // MARK: Ocean

    private func buildOcean(_ layout: PixelSceneSupport.Layout, animated: Bool) {
        canvas.addSublayer(imageLayer("scene_ocean_room"))
        let foam = imageLayer("scene_ocean_foam")
        if animated {
            // The wash: the foam line creeps up the beach and back.
            let wash = CAKeyframeAnimation(keyPath: "position")
            let base = foam.position
            wash.values = [base, CGPoint(x: base.x + 1, y: base.y - 1), CGPoint(x: base.x + 2, y: base.y - 2), base].map { NSValue(point: $0) }
            wash.keyTimes = [0, 0.35, 0.55, 1]
            wash.calculationMode = .discrete
            wash.duration = 7
            wash.repeatCount = .infinity
            wash.isRemovedOnCompletion = false
            foam.add(wash, forKey: "wash")
            foam.add(PixelSceneSupport.flicker(duration: 7, low: 0.45, high: 1, seed: 9, steps: 6), forKey: "fade")
        }
        effects.addSublayer(foam)
        guard animated else { return }
        for (index, point) in (layout.glitter ?? []).enumerated() {
            let glint = sprite("scene_glint", at: point)
            glint.opacity = 0
            glint.add(PixelSceneSupport.blips(duration: 2.2 + Double(index % 7) * 0.4, rest: 0, blip: 0.85, count: 2,
                                              length: 0.25, seed: 300 + index), forKey: "glint")
            effects.addSublayer(glint)
        }
    }

    // MARK: Neon city

    private func buildCyberpunk(_ layout: PixelSceneSupport.Layout, animated: Bool) {
        canvas.addSublayer(imageLayer("scene_cyberpunk_room"))
        guard animated else { return }
        // Neon dropouts: the "off" overlay of a sign group shows briefly.
        for group in 0..<3 {
            let off = imageLayer("scene_cyberpunk_neon\(group)")
            off.opacity = 0
            off.add(PixelSceneSupport.blips(duration: [7.3, 11.9, 5.1][group], rest: 0, blip: 1, count: 3, length: 0.12,
                                            seed: 400 + group), forKey: "dropout")
            effects.addSublayer(off)
        }
        // Single windows going dark (and back) now and then.
        for (index, point) in (layout.windows ?? []).enumerated() {
            let dark = CALayer()
            dark.frame = CGRect(x: Double(point[0]), y: flipY(Double(point[1]), height: 1), width: 1, height: 1)
            dark.backgroundColor = CGColor(red: 0.1, green: 0.09, blue: 0.16, alpha: 1)
            dark.opacity = 0
            dark.add(PixelSceneSupport.blips(duration: 25 + Double(index % 9) * 4, rest: 0, blip: 1, count: 1, length: 8,
                                             seed: 500 + index), forKey: "switch")
            effects.addSublayer(dark)
        }
        // Flying lights along the lanes and over the bridges.
        var random = PixelSceneSupport.Random(6)
        for (index, lane) in (layout.lanes ?? []).enumerated() {
            let light = sprite("scene_cyberpunk_light", at: [lane[0], lane[2]])
            let leftToRight = index % 2 == 0
            let from = Double(leftToRight ? lane[0] : lane[1]), to = Double(leftToRight ? lane[1] : lane[0])
            let y = flipY(Double(lane[2]))
            let travel = Double(lane[1] - lane[0]) / random.range(14, 26)
            let pause = random.range(3, 12)
            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = [NSValue(point: NSPoint(x: from, y: y)), NSValue(point: NSPoint(x: to, y: y)), NSValue(point: NSPoint(x: to, y: y))]
            move.keyTimes = [0, NSNumber(value: travel / (travel + pause)), 1]
            let shown = CAKeyframeAnimation(keyPath: "opacity")
            shown.values = [1, 0, 0]
            shown.keyTimes = [0, NSNumber(value: travel / (travel + pause)), 1]
            shown.calculationMode = .discrete
            let group = CAAnimationGroup()
            group.animations = [move, shown]
            group.duration = travel + pause
            group.repeatCount = .infinity
            group.beginTime = PixelSceneSupport.epoch + random.range(0, 8)
            group.isRemovedOnCompletion = false
            light.add(group, forKey: "fly")
            effects.addSublayer(light)
        }
        effects.addSublayer(rain("scene_cyberpunk_rain", period: 1.2, lean: 0.1, opacity: 0.8, animated: true))
    }

    // MARK: Train

    private func buildTrain(_ layout: PixelSceneSupport.Layout, animated: Bool) {
        // Behind the window: sky (still), valley (slow), trees and overhead
        // line (fast) — then the compartment with its cut-out window.
        canvas.addSublayer(imageLayer("scene_train_sky"))
        canvas.addSublayer(parallax("scene_train_far", period: 120, animated: animated))
        canvas.addSublayer(parallax("scene_train_near", period: 9, animated: animated))
        let cabin = imageLayer("scene_train_cabin")
        if animated {
            // Rail joints: the carriage bumps a pixel, twice, regularly.
            let bump = CAKeyframeAnimation(keyPath: "position.y")
            let y = cabin.position.y
            bump.values = [y, y - 1, y, y - 1, y]
            bump.keyTimes = [0, 0.04, 0.09, 0.16, 0.21]
            bump.calculationMode = .discrete
            bump.duration = 2.4
            bump.repeatCount = .infinity
            bump.isRemovedOnCompletion = false
            cabin.add(bump, forKey: "bump")
        }
        canvas.addSublayer(cabin)
    }
}

// MARK: - Over the UI

/// What the scene throws onto the interface: firelight, drops on the glass,
/// lightning, a few fireflies, neon spill, passing lamps. Additive or
/// sparse, never covering, never hit-testable.
struct PixelSceneGlow: NSViewRepresentable {
    let scene: AmbientSound
    let intensity: Double
    let animated: Bool
    var lastFlash: Date? = nil
    var burnDownEnd: Date? = nil

    func makeNSView(context: Context) -> PixelSceneGlowNSView { PixelSceneGlowNSView() }

    func updateNSView(_ view: PixelSceneGlowNSView, context: Context) {
        view.configure(scene: scene, intensity: intensity, animated: animated, lastFlash: lastFlash)
        view.setBurnDown(burnDownEnd)
    }
}

final class PixelSceneGlowNSView: NSView {
    private let root = CALayer()
    private var built: (scene: AmbientSound, animated: Bool)?
    private var flashLayer: CALayer?
    private var lastFlash: Date?
    private var intensity: Double = 0.6
    /// Screen points per canvas pixel (keeps sprites the scene's size).
    private var artScale: CGFloat { max(2, bounds.height / 180) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(root)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var burnDownEnd: Date?

    func setBurnDown(_ end: Date?) {
        guard end != burnDownEnd else { return }
        burnDownEnd = end
        PixelSceneSupport.applyBurnDown(to: root, end: end, from: root.opacity)
    }

    func configure(scene: AmbientSound, intensity: Double, animated: Bool, lastFlash: Date?) {
        self.intensity = intensity
        if built?.scene != scene || built?.animated != animated {
            built = (scene, animated)
            rebuild()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = Float(0.4 + 0.6 * intensity)
        CATransaction.commit()
        if lastFlash != self.lastFlash {
            let isNew = self.lastFlash != nil || (lastFlash.map { Date().timeIntervalSince($0) < 2 } ?? false)
            self.lastFlash = lastFlash
            if isNew, animated { flashLayer?.add(PixelSceneSupport.lightningFlash(), forKey: "flash") }
        }
    }

    override func layout() {
        super.layout()
        // Sprite sizes and emitter areas depend on the window size.
        if root.frame != bounds { rebuild() }
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.frame = bounds
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        flashLayer = nil
        guard let (scene, animated) = built, bounds.width > 0 else { return }
        switch scene {
        case .fire: addFirelight(animated: animated)
        case .rain: addDrops(animated: animated, rate: 0.5)
        case .storm:
            addDrops(animated: animated, rate: 0.9)
            addFlash()
        case .forest: if animated { addFireflies() }
        case .cyberpunk: addNeonSpill(animated: animated)
        case .train: if animated { addPassingLamps() }
        case .ocean, .water: break
        }
    }

    private func radial(_ colours: [CGColor], centre: CGPoint, reach: CGPoint) -> CAGradientLayer {
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = bounds
        glow.startPoint = centre
        glow.endPoint = reach
        glow.colors = colours
        glow.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        return glow
    }

    private func addFirelight(animated: Bool) {
        let glow = radial([
            CGColor(red: 1.0, green: 0.50, blue: 0.18, alpha: 0.22),
            CGColor(red: 0.9, green: 0.32, blue: 0.10, alpha: 0.10),
            CGColor(red: 0.6, green: 0.18, blue: 0.05, alpha: 0),
        ], centre: CGPoint(x: 0.5, y: 0), reach: CGPoint(x: 1.15, y: 1.05))
        glow.locations = [0, 0.45, 1]
        if animated { glow.add(PixelSceneSupport.flicker(duration: 3.1, low: 0.55, high: 1.0, seed: 1), forKey: "flicker") }
        root.addSublayer(glow)
    }

    /// Raindrops landing on the "glass" in front of the UI and slowly
    /// running down before they fade.
    private func addDrops(animated: Bool, rate: Float) {
        guard animated else { return }
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterShape = .rectangle
        emitter.emitterMode = .surface
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        emitter.emitterSize = bounds.size
        let cell = CAEmitterCell()
        cell.contents = PixelSceneSupport.image("scene_drop")
        cell.magnificationFilter = CALayerContentsFilter.nearest.rawValue
        cell.scale = artScale * 0.6
        cell.birthRate = rate * Float(bounds.width * bounds.height / 1_000_000)
        cell.lifetime = 9
        cell.lifetimeRange = 3
        cell.velocity = 3
        cell.velocityRange = 3
        cell.emissionLongitude = -.pi / 2
        cell.yAcceleration = -0.6
        cell.alphaSpeed = -0.1
        emitter.emitterCells = [cell]
        root.addSublayer(emitter)
    }

    private func addFlash() {
        let flash = CALayer()
        flash.frame = bounds
        flash.backgroundColor = CGColor(red: 0.8, green: 0.86, blue: 1, alpha: 0.28)
        flash.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        flash.opacity = 0
        root.addSublayer(flash)
        flashLayer = flash
    }

    /// A handful of fireflies that wander out of the jungle over the UI.
    private func addFireflies() {
        var random = PixelSceneSupport.Random(77)
        for index in 0..<5 {
            let fly = CALayer()
            fly.contents = PixelSceneSupport.image("scene_firefly")
            fly.magnificationFilter = .nearest
            fly.bounds = CGRect(x: 0, y: 0, width: 3 * artScale, height: 3 * artScale)
            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = (0..<5).map { _ in NSValue(point: NSPoint(x: random.range(0, bounds.width), y: random.range(0, bounds.height * 0.7))) }
            move.calculationMode = .cubicPaced
            move.duration = 30 + Double(index) * 6
            move.autoreverses = true
            move.repeatCount = .infinity
            move.isRemovedOnCompletion = false
            fly.add(move, forKey: "move")
            fly.opacity = 0
            fly.add(PixelSceneSupport.blips(duration: 5 + Double(index), rest: 0, blip: 0.9, count: 2, length: 1.1,
                                            seed: 600 + index, discrete: false), forKey: "glow")
            root.addSublayer(fly)
        }
    }

    private func addNeonSpill(animated: Bool) {
        let magenta = radial([CGColor(red: 0.85, green: 0.25, blue: 0.75, alpha: 0.12), CGColor(red: 0.5, green: 0.1, blue: 0.5, alpha: 0)],
                             centre: CGPoint(x: 0.12, y: 0.35), reach: CGPoint(x: 0.75, y: 1.1))
        let cyan = radial([CGColor(red: 0.2, green: 0.75, blue: 0.95, alpha: 0.10), CGColor(red: 0.1, green: 0.4, blue: 0.6, alpha: 0)],
                          centre: CGPoint(x: 0.92, y: 0.55), reach: CGPoint(x: 0.3, y: 1.2))
        if animated {
            // In step with the left sign group's dropouts (same seed/timing).
            magenta.add(PixelSceneSupport.blips(duration: 7.3, rest: 1, blip: 0.35, count: 3, length: 0.12, seed: 400), forKey: "dropout")
        }
        root.addSublayer(magenta)
        root.addSublayer(cyan)
    }

    /// Lamps along the track sweep a warm band of light across the
    /// compartment (and the UI) now and then.
    private func addPassingLamps() {
        let band = CAGradientLayer()
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [CGColor(red: 1, green: 0.75, blue: 0.45, alpha: 0), CGColor(red: 1, green: 0.75, blue: 0.45, alpha: 0.16),
                       CGColor(red: 1, green: 0.75, blue: 0.45, alpha: 0)]
        band.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        band.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.35, height: bounds.height)
        let sweep = CAKeyframeAnimation(keyPath: "position.x")
        sweep.values = [bounds.width * 1.2, -bounds.width * 0.2, -bounds.width * 0.2]
        sweep.keyTimes = [0, 0.09, 1]
        sweep.duration = 13
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        band.position = CGPoint(x: -bounds.width, y: bounds.midY)
        band.add(sweep, forKey: "sweep")
        root.addSublayer(band)
    }
}
