#if canImport(SceneKit)
import SceneKit
import simd

// Notebook geometry: the book's shapes. Everything is in centimetres in the book's own
// space: x runs from the spine (0) to the fore-edge, y along the spine (0 at the middle), z up from the back board's
// outer face (0) towards the reader. The book lies open with its back board on the ground; the front board, the leaves
// turned so far and the left stack swing about the spine (NotebookRenderer).

/// A pocket field guide's proportions: a page 13 × 19 cm, boards 5 mm proud of it on three sides (3 mm read as none
/// once the block's height hides it), a 22 mm block between 3 mm boards.
enum BookSize {
    static let pageWidth: Float = 13
    static let pageHeight: Float = 19
    static let overhang: Float = 0.5
    static let board: Float = 0.32
    static let block: Float = 2.2
    static let boardWidth = pageWidth + overhang
    static let boardHeight = pageHeight + 2 * overhang
    /// Half the gap between a leaf's two printed faces (they never z-fight, and a leaf reads as paper, not foil).
    static let paperHalf: Float = 0.006
    /// How far a stack's top sits under the leaf lying on it.
    static let stackGap: Float = 0.02
    /// Segments across a page (the bends are smooth at the largest size on an iPad).
    static let segments = 48
}

/// One page's curve across its width, at its spine root: what a leaf, a stack's top and the gutter share.
struct BookCurve {
    /// (x, z) along the page, `BookSize.segments + 1` points from the spine to the fore-edge.
    var points: [SIMD2<Float>]
    /// The recto's normal at each point (the verso's is its opposite).
    var normals: [SIMD2<Float>]

    /// A leaf lying on its stack (right, or `left`) `rise` above the root deep in the binding. Stacked like paper: the
    /// first centimetre of rise is the gutter's curl (`core`); every leaf above lies on the one below, lifted by its
    /// own thickness along the page, easing in from the spine. So leaves stay apart however thick the stack, and a
    /// higher one never dips into a lower one.
    static func rest(left: Bool, root: SIMD2<Float>, rise: Float) -> BookCurve {
        let base = min(rise, coreRise)
        var curve = core(left: left, root: root, rise: base)
        let extra = rise - base
        guard extra > 0.0001 else { return curve }
        let ramp = liftRamp(extra)
        let ds = BookSize.pageWidth / Float(BookSize.segments)
        for i in curve.points.indices {
            let t = min(1, Float(i) * ds / ramp)
            let up = curve.normals[i].y >= 0 ? curve.normals[i] : -curve.normals[i]
            curve.points[i] += up * extra * (t * t * (3 - 2 * t))
        }
        for i in curve.points.indices {
            let a = curve.points[max(0, i - 1)], b = curve.points[min(curve.points.count - 1, i + 1)]
            let tangent = simd_normalize(b - a)
            curve.normals[i] = SIMD2(-tangent.y, tangent.x)
        }
        return curve
    }

    /// The gutter's curl carries this much rise; more is lifted (`rest`).
    static let coreRise: Float = 0.9
    /// How far from the spine a lift has fully come in: the same for every lift, so a higher leaf is higher everywhere.
    static func liftRamp(_ extra: Float) -> Float { 2.4 }

    /// The gutter's curl: from the root it curls up over `gutterWidth(rise)`, tops out `rise` above the root, and slopes
    /// a little down to the fore-edge, as an open block lies in a low arch.
    private static func core(left: Bool, root: SIMD2<Float>, rise: Float) -> BookCurve {
        let n = BookSize.segments
        let width = BookSize.pageWidth
        let ds = width / Float(n)
        let gutter = gutterWidth(rise)
        let lift = gutterLift(rise: rise, width: gutter)
        let droop = 0.06 * min(1, rise / 0.9)
        var points = [SIMD2<Float>](repeating: .zero, count: n + 1)
        var normals = [SIMD2<Float>](repeating: .zero, count: n + 1)
        func phi(_ s: Float) -> Float {
            let u = max(0, 1 - s / gutter)
            let t = max(0, min(1, (s - 0.6 * gutter) / (width - 0.6 * gutter)))
            let a = lift * u * u - droop * t * t * (3 - 2 * t)
            return left ? .pi - a : a
        }
        points[0] = root
        for i in 0...n {
            let s = Float(i) * ds
            let a = phi(s)
            normals[i] = SIMD2(-sin(a), cos(a))
            if i < n {
                let mid = phi(s + ds / 2)
                points[i + 1] = points[i] + ds * SIMD2(cos(mid), sin(mid))
            }
        }
        return BookCurve(points: points, normals: normals)
    }

    /// A leaf turning over, `progress` 0 (lying right, as `right`) … 1 (lying left, as `left`). Seen from above a page
    /// turns by folding over, not by standing up: a curl of `radius` (largest halfway) starts at the fore-edge and rolls
    /// in towards the spine. The page up to the fold stays where it lay, the paper past it comes over the curl and lies
    /// turned on top (its verso up), sliding over the spine onto the left page, while the page beneath shows from the
    /// edge in. No part of the page ever shortens or stretches. At the end it lies exactly as `left`; backwards, the
    /// same unrolled. Nothing passes below `floor(x)` (the stacks).
    static func fold(progress: Float, right: BookCurve, left: BookCurve, radius: Float,
                     floor: (Float) -> Float) -> BookCurve {
        let n = BookSize.segments, width = BookSize.pageWidth, ds = width / Float(n)
        let u = max(0, min(1, progress))
        let r = radius * sin(.pi * u)
        // The fold's place along the page (cm from the spine): the fore-edge travels steadily from x = W to x = −W.
        let c = max(0, min(width, width * (1 - u) - .pi * r / 2))
        // The page as paper: each stretch's direction and length. Up to the fold it lies as it lay; in the curl it
        // turns over at 1/r; past the curl it lies turned, heading left and a touch down, as a page lying left does.
        let lying = chain(right.points)
        let foldAngle = lying.angles[min(n - 1, Int(c / ds))], over = Float.pi + 0.04
        var angles = [Float](), lengths = [Float]()
        for i in 0..<n {
            let middle = (Float(i) + 0.5) * ds
            if middle <= c {
                angles.append(lying.angles[i])
                lengths.append(lying.lengths[i])
            } else {
                angles.append(r > 1e-4 ? min(over, foldAngle + (middle - c) / r) : over)
                lengths.append(ds)
            }
        }
        // In its last stretch the crease comes over too and the page settles into the left page's own shape (its
        // gutter curl): each stretch turns to its direction lying left, so the page never shortens on the way.
        let x = max(0, min(1, (u - 0.65) / 0.35)), settle = x * x * (3 - 2 * x)
        let to = chain(left.points)
        var points = [right.points[0] + (left.points[0] - right.points[0]) * settle]
        points.reserveCapacity(n + 1)
        for i in 0..<n {
            let angle = angles[i] + (to.angles[i] - angles[i]) * settle
            let length = lengths[i] + (to.lengths[i] - lengths[i]) * settle
            points.append(points[i] + length * SIMD2(cos(angle), sin(angle)))
        }
        for i in points.indices { points[i].y = max(points[i].y, floor(points[i].x) + 0.01) }
        var normals = [SIMD2<Float>]()
        normals.reserveCapacity(n + 1)
        var last = SIMD2<Float>(0, 1)
        for i in 0...n {
            let d = points[min(n, i + 1)] - points[max(0, i - 1)]
            if simd_length(d) > 1e-6 {
                let tangent = simd_normalize(d)
                last = SIMD2(-tangent.y, tangent.x)
            }
            normals.append(last)
        }
        return BookCurve(points: points, normals: normals)
    }

    /// A polyline's segments as directions (unwrapped, so they turn continuously) and lengths.
    private static func chain(_ points: [SIMD2<Float>]) -> (angles: [Float], lengths: [Float]) {
        var angles = [Float](), lengths = [Float]()
        angles.reserveCapacity(points.count - 1)
        lengths.reserveCapacity(points.count - 1)
        for i in 0..<(points.count - 1) {
            let d = points[i + 1] - points[i]
            var a = atan2(d.y, d.x)
            if let previous = angles.last {
                while a - previous > .pi { a -= 2 * .pi }
                while a - previous < -.pi { a += 2 * .pi }
            }
            angles.append(a)
            lengths.append(simd_length(d))
        }
        return (angles, lengths)
    }

    /// The gutter's width for a stack this far above the root: a thicker stack curls over a wider gutter.
    static func gutterWidth(_ rise: Float) -> Float { min(2.6, 1.2 + 1.3 * max(0, rise)) }

    /// The page's angle where it leaves the spine, so that it climbs `rise` over `width` (u² falloff): bisection.
    static func gutterLift(rise: Float, width: Float) -> Float {
        guard rise > 0.0005 else { return 0 }
        func climb(_ lift: Float) -> Float {
            let steps = 16
            let ds = width / Float(steps)
            var z: Float = 0
            for i in 0..<steps {
                let u = 1 - (Float(i) + 0.5) / Float(steps)
                z += ds * sin(lift * u * u)
            }
            return z
        }
        var low: Float = 0, high: Float = 1.45
        if climb(high) <= rise { return high }
        for _ in 0..<18 {
            let mid = (low + high) / 2
            if climb(mid) < rise { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}

/// Meshes rebuilt as the book moves. Index buffers and texture coordinates never change, so they are made once.
#if os(iOS)
enum BookMesh {
    private static let leafIndices: (recto: [UInt16], verso: [UInt16]) = {
        var recto = [UInt16](), verso = [UInt16]()
        for i in 0..<BookSize.segments {
            let a = UInt16(2 * i), b = UInt16(2 * i + 2), c = UInt16(2 * i + 3), d = UInt16(2 * i + 1)
            // Two rows per column: even = foot (y −H/2), odd = head (y +H/2).
            recto += [a, b, c, a, c, d]
            verso += [a, c, b, a, d, c]
        }
        return (recto, verso)
    }()

    private static let leafCoordinates: (recto: [CGPoint], verso: [CGPoint]) = {
        var recto = [CGPoint](), verso = [CGPoint]()
        for i in 0...BookSize.segments {
            let u = CGFloat(i) / CGFloat(BookSize.segments)
            recto += [CGPoint(x: u, y: 1), CGPoint(x: u, y: 0)]
            verso += [CGPoint(x: 1 - u, y: 1), CGPoint(x: 1 - u, y: 0)]
        }
        return (recto, verso)
    }()

    /// One face of a leaf along `curve` (the recto, or the verso offset the other way and facing it).
    static func leafFace(_ curve: BookCurve, verso: Bool, transform: (SIMD2<Float>) -> SIMD2<Float> = { $0 },
                         normalTransform: (SIMD2<Float>) -> SIMD2<Float> = { $0 }) -> SCNGeometry {
        let half = BookSize.pageHeight / 2
        let side: Float = verso ? -1 : 1
        var vertices = [SCNVector3](), normals = [SCNVector3]()
        vertices.reserveCapacity(curve.points.count * 2)
        normals.reserveCapacity(curve.points.count * 2)
        for (point, normal) in zip(curve.points, curve.normals) {
            let p = transform(point + side * BookSize.paperHalf * normal)
            let n = normalTransform(side * normal)
            vertices += [SCNVector3(p.x, -half, p.y), SCNVector3(p.x, half, p.y)]
            normals += [SCNVector3(n.x, 0, n.y), SCNVector3(n.x, 0, n.y)]
        }
        let element = SCNGeometryElement(indices: verso ? leafIndices.verso : leafIndices.recto, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
                                     SCNGeometrySource(textureCoordinates: verso ? leafCoordinates.verso : leafCoordinates.recto)],
                           elements: [element])
    }

    /// A stack of leaves under `top` (a leaf's curve), down to `floor`: its top (hidden under the top leaf), the
    /// fore-edge, and the head and tail. Page edges are lettered by `edgeRepeat` (cm per tile of the edge texture).
    /// `extra`: the thickness of pages on their way onto (or off) this stack. Its edges (fore-edge, head and tail)
    /// stand that much higher, lifting in from the spine as stacked leaves do, while its top stays under its top leaf:
    /// a stack thickens as a page comes down onto it and thins as one lifts away.
    static func stack(top: BookCurve, floor: Float, extra: Float = 0,
                      transform: (SIMD2<Float>) -> SIMD2<Float> = { $0 },
                      normalTransform: (SIMD2<Float>) -> SIMD2<Float> = { $0 }) -> SCNGeometry {
        let half = BookSize.pageHeight / 2
        let edgeTile: Float = 1.2
        // The profile (convex): the top curve lowered under its leaf (along the face that looks up: the recto's on
        // the right, the verso's on the left) and raised by `extra`, then the fore-edge's foot and the spine's foot.
        let up = top.normals.map { $0.y >= 0 ? $0 : -$0 }
        let lowered = zip(top.points, up).map { $0 - BookSize.stackGap * $1 }
        let ds = BookSize.pageWidth / Float(BookSize.segments), ramp = BookCurve.liftRamp(extra)
        var profile = lowered.enumerated().map { i, p in
            let t = min(1, Float(i) * ds / ramp)
            return p + up[i] * extra * (t * t * (3 - 2 * t))
        }
        let edge = profile[profile.count - 1]
        profile.append(SIMD2(edge.x, floor))
        profile.append(SIMD2(profile[0].x, floor))

        var vertices = [SCNVector3](), normals = [SCNVector3](), coordinates = [CGPoint](), indices = [UInt16]()
        func add(_ p: SIMD2<Float>, _ y: Float, _ n: SIMD3<Float>, _ uv: CGPoint) -> UInt16 {
            let q = transform(p)
            let m = normalTransform(SIMD2(n.x, n.z))
            vertices.append(SCNVector3(q.x, y, q.y))
            normals.append(SCNVector3(m.x, n.y, m.y))
            coordinates.append(uv)
            return UInt16(vertices.count - 1)
        }
        // The fore-edge: lines along y, one per leaf, stacked in z.
        let foot = profile[profile.count - 2]
        let outward = simd_normalize(SIMD2(top.normals.last!.y, -top.normals.last!.x)) // along the page, out
        let n3 = SIMD3(outward.x, 0, outward.y)
        let v0 = CGFloat(edge.y / edgeTile), v1 = CGFloat(foot.y / edgeTile)
        let a = add(edge, -half, n3, CGPoint(x: 0, y: v0)), b = add(edge, half, n3, CGPoint(x: 4, y: v0))
        let c = add(foot, half, n3, CGPoint(x: 4, y: v1)), d = add(foot, -half, n3, CGPoint(x: 0, y: v1))
        // Facing out along +x (right stack): a, d, c / a, c, b is counter-clockwise seen from outside.
        indices += outward.x >= 0 ? [a, d, c, a, c, b] : [a, c, d, a, b, c]
        // The spine side: the leaves' backs glued together, from the spine's foot up to the first leaf's root (the
        // binding seen when the book swings open; double-sided material, so its winding does not matter).
        let spineFoot = profile[profile.count - 1], spineTop = profile[0]
        let s0 = CGFloat(spineFoot.y / edgeTile), s1 = CGFloat(spineTop.y / edgeTile)
        let e = add(spineTop, -half, -n3, CGPoint(x: 0, y: s1)), f = add(spineTop, half, -n3, CGPoint(x: 4, y: s1))
        let g = add(spineFoot, half, -n3, CGPoint(x: 4, y: s0)), h = add(spineFoot, -half, -n3, CGPoint(x: 0, y: s0))
        indices += [e, h, g, e, g, f]
        // Head (+y) and tail (−y): fans over the convex profile.
        for (y, ny) in [(half, Float(1)), (-half, Float(-1))] {
            let first = UInt16(vertices.count)
            for p in profile {
                _ = add(p, y, SIMD3(0, ny, 0), CGPoint(x: CGFloat(p.x / edgeTile), y: CGFloat(p.y / edgeTile)))
            }
            let count = UInt16(profile.count)
            // Seen from +y the profile's order (spine to fore-edge along the top, back along the floor) runs
            // clockwise in (x, z); a fan keeps it, so the head flips the winding and the tail keeps it.
            for k in 1..<(count - 1) {
                let tri = ny > 0 ? [first, first + k + 1, first + k] : [first, first + k, first + k + 1]
                indices += outward.x >= 0 ? tri : [tri[0], tri[2], tri[1]]
            }
        }
        // The top, just under the top leaf (its gutter shows where the leaf is thin at the spine).
        let topFirst = UInt16(vertices.count)
        for i in 0..<top.points.count {
            let p = lowered[i]
            let n = up[i]
            _ = add(p, -half, SIMD3(n.x, 0, n.y), CGPoint(x: 0, y: 0))
            _ = add(p, half, SIMD3(n.x, 0, n.y), CGPoint(x: 0, y: 0))
        }
        for i in 0..<(top.points.count - 1) {
            let a = topFirst + UInt16(2 * i), b = a + 2, c = a + 3, d = a + 1
            indices += outward.x >= 0 ? [a, b, c, a, c, d] : [a, c, b, a, d, c]
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
                                     SCNGeometrySource(textureCoordinates: coordinates)], elements: [element])
    }

    /// The spine's leather from the back board's spine edge `from` to the front board's `to`, rounded outward along
    /// `bulge` (a unit direction).
    static func spine(from: SIMD2<Float>, to: SIMD2<Float>, bulge: SIMD2<Float>) -> SCNGeometry {
        let half = BookSize.boardHeight / 2
        let length = simd_length(to - from)
        let reach = 0.22 * max(length, 0.3)
        let p0 = from, p1 = from + reach * bulge, p2 = to + reach * bulge, p3 = to
        let steps = 16
        var vertices = [SCNVector3](), normals = [SCNVector3](), coordinates = [CGPoint](), indices = [UInt16]()
        for i in 0...steps {
            let t = Float(i) / Float(steps), m = 1 - t
            let p = m * m * m * p0 + 3 * m * m * t * p1 + 3 * m * t * t * p2 + t * t * t * p3
            let d = 3 * m * m * (p1 - p0) + 6 * m * t * (p2 - p1) + 3 * t * t * (p3 - p2)
            var n = simd_length(d) > 1e-5 ? SIMD2(d.y, -d.x) / simd_length(d) : bulge
            if simd_dot(n, bulge) < 0 { n = -n }
            vertices += [SCNVector3(p.x, -half, p.y), SCNVector3(p.x, half, p.y)]
            normals += [SCNVector3(n.x, 0, n.y), SCNVector3(n.x, 0, n.y)]
            coordinates += [CGPoint(x: CGFloat(t), y: 1), CGPoint(x: CGFloat(t), y: 0)]
            if i < steps {
                let a = UInt16(2 * i), b = a + 2, c = a + 3, d = a + 1
                indices += [a, b, c, a, c, d]
            }
        }
        // The headbands: the spine's section closed at the block's head and tail (cloth caps, the second element).
        var caps = [UInt16]()
        let curve = Array(vertices.indices.filter { $0 % 2 == 0 }).map { vertices[$0] }
        let block = BookSize.pageHeight / 2
        for (y, ny) in [(block, Float(1)), (-block, Float(-1))] {
            let first = UInt16(vertices.count)
            let centre = curve.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.x, $1.z) } / Float(curve.count)
            vertices.append(SCNVector3(centre.x, y, centre.y))
            normals.append(SCNVector3(0, ny, 0))
            coordinates.append(CGPoint(x: 0.5, y: 0.5))
            for (k, v) in curve.enumerated() {
                vertices.append(SCNVector3(v.x, y, v.z))
                normals.append(SCNVector3(0, ny, 0))
                coordinates.append(CGPoint(x: CGFloat(k) / CGFloat(curve.count - 1) * 6, y: 1))
            }
            let count = UInt16(curve.count)
            for k in 1...count {
                let a = first + k, b = first + (k % count) + 1
                caps += ny > 0 ? [first, a, b] : [first, b, a]
            }
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let capElement = SCNGeometryElement(indices: caps, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
                                     SCNGeometrySource(textureCoordinates: coordinates)], elements: [element, capElement])
    }
}
#endif
#endif
