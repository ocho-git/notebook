#if os(iOS)
import SceneKit
import UIKit

// Notebook: the book's materials, all drawn here (no image assets): a brown leather with a pebbled
// grain, a gold-foil title, paper, the page edges' fine lines, and a soft room to reflect in.

enum BookMaterials {
    /// sRGB colours (SceneKit converts UIColor to linear).
    static let leather = UIColor(red: 0.30, green: 0.19, blue: 0.13, alpha: 1)
    static let paper = UIColor(red: 0.95, green: 0.93, blue: 0.87, alpha: 1)
    static let foil = UIColor(red: 0.86, green: 0.70, blue: 0.40, alpha: 1)
    /// The scrim laid over the garden while the book is open (NotebookView, at BookMotion.scrim).
    static let scrim = UIColor(red: 0.02, green: 0.03, blue: 0.03, alpha: 1)

    /// The cover's leather. `repeats`: grain tiles across the face (a board's face is about 13 × 20 cm).
    static func leather(repeats: CGSize, color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = grain.albedo
        m.multiply.contents = color
        m.normal.contents = grain.normal
        m.normal.intensity = 0.8
        m.roughness.contents = 0.55
        m.metalness.contents = 0.0
        // A waxed leather's soft sheen.
        m.clearCoat.contents = 0.35
        m.clearCoatRoughness.contents = 0.32
        for property in [m.diffuse, m.normal] {
            property.wrapS = .repeat
            property.wrapT = .repeat
            property.contentsTransform = SCNMatrix4MakeScale(Float(repeats.width), Float(repeats.height), 1)
            property.mipFilter = .linear
        }
        return m
    }

    /// A printed page (its picture comes later: NotebookPage). `spineAtStart`: the spine is at the texture's
    /// u = 0 (a recto) rather than u = 1 (a verso); the gutter darkens towards it.
    static func page(spineAtStart: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = paper
        m.diffuse.mipFilter = .linear
        m.roughness.contents = 0.8
        m.metalness.contents = 0.0
        m.multiply.contents = spineAtStart ? gutter.recto : gutter.verso
        m.ambientOcclusion.contents = spineAtStart ? gutter.recto : gutter.verso
        return m
    }

    /// The gutter's shade across a page (spine at the left for a recto, at the right for a verso).
    static let gutter: (recto: UIImage, verso: UIImage) = {
        let width = 128
        func shade(_ u: Float) -> Float {
            let t = min(1, u / 0.2)
            return 0.7 + 0.3 * (t * t * (3 - 2 * t))
        }
        let recto = pixels(width: width, height: 1) { x, _ in SIMD4(SIMD3(repeating: shade(Float(x) / Float(width - 1))), 1) }
        let verso = pixels(width: width, height: 1) { x, _ in SIMD4(SIMD3(repeating: shade(1 - Float(x) / Float(width - 1))), 1) }
        return (recto, verso)
    }()

    /// The block's page edges.
    static func edges() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = edgeLines
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.roughness.contents = 0.9
        m.isDoubleSided = true
        return m
    }

    /// The headbands at the spine's ends: a cloth band, striped red and cream.
    static func headband() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = pixels(width: 8, height: 1) { x, _ in
            x % 4 < 2 ? SIMD4(0.55, 0.16, 0.12, 1) : SIMD4(0.90, 0.86, 0.76, 1)
        }
        m.diffuse.wrapS = .repeat
        m.diffuse.magnificationFilter = .nearest
        m.roughness.contents = 0.85
        m.isDoubleSided = true
        return m
    }

    /// The foil on the front board: gold where `title` is opaque.
    static func foilTitle(mask: UIImage, color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 1.0
        m.roughness.contents = 0.32
        m.transparent.contents = mask
        m.transparencyMode = .aOne
        m.writesToDepthBuffer = false
        return m
    }

    /// The ground's shadow (and nothing else).
    static func shadowCatcher() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .shadowOnly
        m.writesToDepthBuffer = false
        return m
    }

    /// A light room: bright overhead, warm at the horizon, dim below (the leather's sheen and the foil's glint).
    static let environment: UIImage = {
        let width = 256, height = 128
        return pixels(width: width, height: height) { _, y in
            let t = Float(y) / Float(height - 1) // 0 top … 1 bottom
            let top = SIMD3<Float>(0.97, 0.97, 0.96), horizon = SIMD3<Float>(0.82, 0.81, 0.78)
            let ground = SIMD3<Float>(0.30, 0.30, 0.29)
            let c = t < 0.5 ? simd_mix(top, horizon, SIMD3(repeating: t / 0.5))
                            : simd_mix(horizon, ground, SIMD3(repeating: min(1, (t - 0.5) / 0.2)))
            return SIMD4(c, 1)
        }
    }()

    // MARK: - Drawn textures

    /// The leather's grain, a tile that repeats seamlessly: a network of fine creases between soft pebbles.
    static let grain: (albedo: UIImage, normal: UIImage) = {
        let size = 256
        var height = [Float](repeating: 0, count: size * size)
        let coarse = PeriodicNoise(period: 18, seed: 11), mid = PeriodicNoise(period: 36, seed: 23)
        let fine = PeriodicNoise(period: 90, seed: 37)
        for y in 0..<size {
            for x in 0..<size {
                let u = Float(x) / Float(size), v = Float(y) / Float(size)
                let creases = 1 - abs(2 * coarse.value(u, v) - 1)       // ridges where the noise crosses ½
                let pebbles = mid.value(u, v)
                height[y * size + x] = 0.55 * (1 - creases * creases) + 0.3 * pebbles + 0.15 * fine.value(u, v)
            }
        }
        func h(_ x: Int, _ y: Int) -> Float { height[((y + size) % size) * size + (x + size) % size] }
        let base = SIMD3<Float>(repeating: 1)
        let albedo = pixels(width: size, height: size) { x, y in
            let value = h(x, y)
            return SIMD4(base * (0.72 + 0.42 * value), 1)
        }
        let strength: Float = 3.2
        let normal = pixels(width: size, height: size) { x, y in
            let dx = (h(x + 1, y) - h(x - 1, y)) * strength, dy = (h(x, y + 1) - h(x, y - 1)) * strength
            let n = simd_normalize(SIMD3(-dx, dy, 1))
            return SIMD4(n * 0.5 + 0.5, 1)
        }
        return (albedo, normal)
    }()

    /// The page edges: one fine line per few leaves, each a shade off its neighbours, with a darker seam between.
    static let edgeLines: UIImage = {
        let width = 8, height = 256, lines = 40
        var random = SplitMix(seed: 7)
        let shades = (0..<lines).map { _ in Float(0.93 + 0.07 * random.unit()) }
        let paper = SIMD3<Float>(0.95, 0.93, 0.87)
        return pixels(width: width, height: height) { _, y in
            let line = y * lines / height
            let seam = (y * lines) % height < lines ? 0.86 : 1.0
            return SIMD4(paper * shades[line] * Float(seam), 1)
        }
    }()

    /// Per-instance cover lettering. No app assets or font registration are required.
    static func titleMask(_ cover: NotebookCover, turned: Bool) -> UIImage {
        let size = CGSize(width: 1064, height: 1568)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setStroke()
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 40, dy: 40)
            let rule = UIBezierPath(roundedRect: frame, cornerRadius: 8)
            rule.lineWidth = 5
            rule.stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Baskerville-SemiBold", size: 100) ?? UIFont.systemFont(ofSize: 100),
                .foregroundColor: UIColor.white, .paragraphStyle: paragraph
            ]
            (cover.title as NSString).draw(in: CGRect(x: 290, y: 300, width: 650, height: 800), withAttributes: attributes)
            let cg = context.cgContext
            cg.saveGState()
            cg.translateBy(x: 150, y: size.height / 2)
            cg.rotate(by: turned ? .pi / 2 : -.pi / 2)
            (cover.spineTitle as NSString).draw(in: CGRect(x: -620, y: -55, width: 1240, height: 180), withAttributes: attributes)
            cg.restoreGState()
        }
    }

    /// Fine paper fibre, laid over every printed page (NotebookPage).
    static let fibre: UIImage = {
        let size = 128
        var random = SplitMix(seed: 3)
        let noise = (0..<(size * size)).map { _ in random.unit() }
        return pixels(width: size, height: size) { x, y in
            let v = noise[y * size + x]
            // A few dark flecks in a faint mottle.
            return v > 0.992 ? SIMD4(0.25, 0.24, 0.2, 0.22) : SIMD4(0.5, 0.48, 0.42, 0.035 * v)
        }
    }()

    static func pixels(width: Int, height: Int, _ color: (Int, Int) -> SIMD4<Float>) -> UIImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = simd_clamp(color(x, y), SIMD4(repeating: 0), SIMD4(repeating: 1))
                let i = (y * width + x) * 4
                // Premultiplied alpha.
                bytes[i] = UInt8(c.x * c.w * 255)
                bytes[i + 1] = UInt8(c.y * c.w * 255)
                bytes[i + 2] = UInt8(c.z * c.w * 255)
                bytes[i + 3] = UInt8(c.w * 255)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: image)
    }
}

/// Value noise that wraps every `period` cells across [0, 1).
struct PeriodicNoise {
    let period: Int
    private let lattice: [Float]

    init(period: Int, seed: UInt64) {
        self.period = period
        var random = SplitMix(seed: seed)
        lattice = (0..<(period * period)).map { _ in random.unit() }
    }

    func value(_ u: Float, _ v: Float) -> Float {
        let x = u * Float(period), y = v * Float(period)
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = x - Float(x0), fy = y - Float(y0)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        func at(_ i: Int, _ j: Int) -> Float { lattice[((j % period + period) % period) * period + (i % period + period) % period] }
        let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * sx
        let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * sx
        return top + (bottom - top) * sy
    }
}

#endif
