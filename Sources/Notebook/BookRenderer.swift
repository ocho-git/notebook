#if os(iOS)
import SceneKit
import UIKit
import simd

// Notebook: the scene and its motion. The controller (main thread) says what the book should do (be
// open, which leaves lie left, a leaf under the finger); this renderer animates towards it on SceneKit's render thread,
// once per frame while the view plays, and tells the controller when it has settled so the view can stop drawing (a
// closed book in the corner costs nothing).

/// The motion's knobs, in one place for tuning.
enum BookMotion {
    /// The open book floats this high (cm) over the garden, tipped back a little (radians) so its edges show; on its
    /// way between the corner and the middle it rises `flightArc` more and tips `flightTip` more.
    static let openLift: Float = 2.6
    static let openTilt: Float = 0.12
    static let flightArc: Float = 4
    static let flightTip: Float = 0.16
    /// Springs: response (s) and damping fraction, as SwiftUI's.
    static let flight: (response: Float, damping: Float) = (0.62, 0.86)
    /// Closed, stepping off the screen while it isn't needed (the menu, the splash, the introduction, a finished garden)
    /// and back.
    static let stow: (response: Float, damping: Float) = (0.55, 1)
    /// Stepping off, it goes on well past the edge (this many times what clears it) and shrinks to `stowScale` on the
    /// way ("2-3x as far" and "maybe like a 0.8 scale").
    static let stowReach: Float = 2.5
    static let stowScale: Float = 0.8
    static let cover: (response: Float, damping: Float) = (1.0, 0.95)
    /// A leaf's turn (its progress through the fold, BookCurve.fold): lightly damped, so a page drops onto its
    /// stack and stops there (the turn stops at the stack: no bounce) instead of creeping the last of the way.
    static let leaf: (response: Float, damping: Float) = (0.5, 0.7)
    /// A leaf turned by a tap: over at a reading pace (tapped turns were "too fast"); a leaf let go from a
    /// finger, or riffled through, keeps `leaf`.
    static let tappedLeaf: (response: Float, damping: Float) = (0.78, 0.74)
    /// Opening: the cover starts to swing once the flight is this far along. Closing: the book starts home once the
    /// cover is this far shut.
    static let coverStarts: Float = 0.72
    static let flightReturns: Float = 0.3
    /// Opening, the pages answer a finger once the cover is this far over (of a half turn); a page sent over before it
    /// lies open makes the cover finish at `coverHurry`.
    static let openForHand: Float = 0.33
    static let coverHurry: (response: Float, damping: Float) = (0.32, 1)
    /// The curl a page folds over with, at its largest halfway through a turn (cm).
    static let foldRadius: Float = 1.4
    /// The dark scrim over the garden while the book is open (a subtle one), and how long it takes to fade in or out
    /// (NotebookView: on the whole screen, apart from the book's view).
    static let scrim: Double = 0.24
    /// The phone turned: the camera rolls and the book glides to its new place, as the garden's own turn does
    /// (NotebookView's 0.35 s ease in and out).
    static let turn: Float = 0.35
    /// The closed book pressed: this much smaller, quickly in and back with a little give.
    static let pressDepth: Float = 0.05
    static let press: (response: Float, damping: Float) = (0.16, 0.62)
    static let scrimFade: Double = 0.5
}

/// Where the book goes, in world centimetres on the ground plane (z = 0): the controller's arithmetic from the view's
/// size, so that one point on the ground is `unitsPerPoint` cm.
struct BookLayout: Equatable, Sendable {
    var viewHeight: Float = 844
    var unitsPerPoint: Float = 0.05
    var cameraDistance: Float = 85
    /// Closed at its edge: its middle, size and turn, and how far it moves to step off the screen.
    var compactCenter = SIMD2<Float>(0, 0)
    var compactStow = SIMD2<Float>(0, 0)
    var compactScale: Float = 0.15
    var compactRoll: Float = -0.08
    /// Closed along the top edge (its spine down): the cover's title band printed turned, to read level from there.
    var titleTurned = false
    /// Closed in the middle (the cover centred), and where the spine goes once open.
    var largeCenter = SIMD2<Float>(0, 0)
    var largeScale: Float = 1
    var openSpine = SIMD2<Float>(0, 0)
    /// The camera's roll about its view axis: the screen turned to face the holder (a quarter turn per
    /// NotebookView.quarterTurns; the ground's frame is the holder's).
    var roll: Float = 0

    /// Part of the way from `a` to `b` (`t` 0…1): places and turns straight, sizes by ratio, edges' rolls the short way
    /// round.
    static func mix(_ a: BookLayout, _ b: BookLayout, _ t: Float) -> BookLayout {
        func lerp(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        func lerp(_ x: SIMD2<Float>, _ y: SIMD2<Float>) -> SIMD2<Float> { x + (y - x) * t }
        func ratio(_ x: Float, _ y: Float) -> Float { exp(lerp(log(x), log(y))) }
        func angle(_ x: Float, _ y: Float) -> Float { x + remainder(y - x, 2 * .pi) * t }
        var m = b
        m.viewHeight = lerp(a.viewHeight, b.viewHeight)
        m.compactCenter = lerp(a.compactCenter, b.compactCenter)
        m.compactStow = lerp(a.compactStow, b.compactStow)
        m.compactScale = ratio(a.compactScale, b.compactScale)
        m.compactRoll = angle(a.compactRoll, b.compactRoll)
        m.largeCenter = lerp(a.largeCenter, b.largeCenter)
        m.largeScale = ratio(a.largeScale, b.largeScale)
        m.openSpine = lerp(a.openSpine, b.openSpine)
        m.roll = lerp(a.roll, b.roll)
        return m
    }
}

struct BookTextureKey: Hashable, Sendable {
    let leaf: Int
    let verso: Bool
    static let frontPastedown = BookTextureKey(leaf: -1, verso: true)
    static let backPastedown = BookTextureKey(leaf: -2, verso: false)
}

/// A leaf under the finger: its angle, and which way it is being turned.
struct BookDrag: Equatable, Sendable {
    var leaf: Int
    var angle: Float
    var forward: Bool
}

/// DEBUG stills: hold one motion at a value (renderer test fixtures).
enum BookFreeze: Sendable, Equatable {
    case turn(Float)
    case cover(Float)
    case flight(Float)
}

enum BookEvent: Sendable {
    case opened, closed, idle
    /// Closing, the book starts home (its scrim fades).
    case homeward
}

/// What the controller asks for.
struct BookInput {
    var layout = BookLayout()
    var open = false
    var presentationID: UInt64 = 0
    var restartIdleDetection = false
    /// The garden's light.
    var light = NotebookLighting()
    /// Closed, it steps off the screen.
    var stowed = false
    /// Open, pulled down this far by a finger (points; nil: let go).
    var lowered: Float?
    var turned: [Bool] = []
    var drag: BookDrag?
    var release: (leaf: Int, velocity: Float)?
    /// The leaf a tap has just sent over (it goes at `BookMotion.tappedLeaf`).
    var tapped: Int?
    /// New page pictures: textures with their mipmaps made (or, if that failed, the picture itself; nil: plain paper).
    var textures: [BookTextureKey: Any?] = [:]
    var freeze: BookFreeze?
    /// Jump straight to the targets (a DEBUG start in an open book).
    var snap = false
    /// The closed book is under a finger.
    var pressed = false
    /// A new layout from the phone turning glides there (BookMotion.turn); otherwise it is taken at once.
    var turnAnimates = false
}

final class NotebookRenderer: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    weak var controller: NotebookController?

    private let lock = NSLock()
    private var pending = BookInput()

    private let leafCount: Int
    private let bookNode = SCNNode()
    private let backBoard = SCNNode()
    private let rightStack = SCNNode()
    private let leftGroup = SCNNode()
    private let leftStack = SCNNode()
    private let frontBoard = SCNNode()
    private let foil = SCNNode()
    private let key = SCNLight()
    private let keyNode = SCNNode()
    private let ambient = SCNLight()
    private var litBy: NotebookLighting?
    private let spine = SCNNode()
    private var leaves: [(root: SCNNode, recto: SCNNode, verso: SCNNode)] = []
    private var pageMaterials: [BookTextureKey: SCNMaterial] = [:]
    // The grain's tile is about 2.6 cm across on every face: a board's faces, its long and short edges, the spine.
    private let leatherMaterial: SCNMaterial
    private let leatherSide: SCNMaterial
    private let leatherEnd: SCNMaterial
    private let spineMaterial: SCNMaterial
    private let coverStyle: NotebookCover
    private let titleMask: UIImage
    private let titleMaskTurned: UIImage
    private let edgeMaterial = BookMaterials.edges()
    private let headband = BookMaterials.headband()

    private var flight = BookSpring(0, BookMotion.flight)
    private var stow = BookSpring(0, BookMotion.stow)
    /// The open book pulled down (points): it follows the finger, springs back when let go, and when it is put away it
    /// stays where it was let go and fades out as the book flies home.
    private var lowered = BookSpring(0, (0.38, 0.9))
    private var stowStarted = false
    private var cover = BookSpring(0, BookMotion.cover)
    /// Each leaf's turn (0 right … π left), and the side each lies on when it is not in the air.
    private var angles: [BookSpring]
    private var liesLeft: [Bool]
    /// DEBUG `-ZenFieldGuideFreeze turn:…`: the leaf held in the air.
    private var frozenLeaf: Int?
    /// The layout shown this frame, and the one asked for (they differ while the phone's turn plays: `turning`, from
    /// the layout shown when it began, how far through it is).
    private var layout = BookLayout()
    private var target = BookLayout()
    private var turning: (from: BookLayout, t: Float)?
    /// Closed, the phone turned and the book's place on the glass changed: it steps off at its edge, takes the new
    /// layout out of sight, and comes back in at its new edge.
    private var relocating = false
    /// Closed where it already lies on the glass, the phone turned: its shadow fades out, the camera rolls (the light
    /// with the holder's frame), and it fades back in, as the garden's light cross-fades (the host lighting transition).
    private var shadowTurn: Float?
    /// The closed book under a finger ("a little press down scale", so it feels responsive).
    private var press = BookSpring(0, BookMotion.press)
    private var lastTime: TimeInterval?
    private var quietFrames = 0
    /// The book's sounds hear its motion: each frame worked out here (springs in) and handed to the feed (BookSounds).
    let soundFeed = BookSoundFeed()
    private var soundTracker = BookSoundTracker()
    private var presentationID: UInt64 = 0
    private var reportedOpen = false
    private var reportedClosed = true
    private var flyingOut = false
    /// What each mesh was last built from (its curve, and what else shapes it): a mesh is made again only when that
    /// changes, so a frame where only some of the book moves (the flight, one leaf turning) builds only those.
    private var rightStackShape: BookShape?
    private var leftStackShape: BookShape?
    private var spineShape: SIMD3<Float>?
    private var leafShapes: [BookShape?]

    init(leafCount: Int, cover: NotebookCover) {
        self.coverStyle = cover
        titleMask = BookMaterials.titleMask(cover, turned: false)
        titleMaskTurned = BookMaterials.titleMask(cover, turned: true)
        leatherMaterial = BookMaterials.leather(repeats: CGSize(width: 5, height: 7.4), color: cover.leatherColor)
        leatherSide = BookMaterials.leather(repeats: CGSize(width: 0.12, height: 7.4), color: cover.leatherColor)
        leatherEnd = BookMaterials.leather(repeats: CGSize(width: 5, height: 0.12), color: cover.leatherColor)
        spineMaterial = BookMaterials.leather(repeats: CGSize(width: 1, height: 7.4), color: cover.leatherColor)
        self.leafCount = leafCount
        angles = Array(repeating: BookSpring(0, BookMotion.leaf), count: leafCount)
        liesLeft = Array(repeating: false, count: leafCount)
        leafShapes = Array(repeating: nil, count: leafCount)
        super.init()
        build()
    }

    /// Main thread: change what the book should do (the view must be playing for it to show).
    func update(_ change: (inout BookInput) -> Void) {
        lock.lock()
        change(&pending)
        pending.restartIdleDetection = true
        lock.unlock()
    }

    /// The book's shadow at the garden's full cast-shadow strength (half what it was, 0.45, everywhere).
    static let shadowStrength: Float = 0.225

    // MARK: - The scene

    private func build() {
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = BookMaterials.environment
        scene.lightingEnvironment.intensity = 0.95

        let camera = SCNCamera()
        camera.projectionDirection = .vertical
        camera.zNear = 20
        camera.zFar = 200
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        // The garden's sun (or moon): placed by `light(_:)` from the garden's lighting, soft.
        key.type = .directional
        key.intensity = 720
        key.color = UIColor(red: 1, green: 0.99, blue: 0.97, alpha: 1)
        key.castsShadow = true
        key.shadowMode = .forward
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowSampleCount = 24
        key.shadowRadius = 7
        key.shadowColor = UIColor(white: 0, alpha: CGFloat(Self.shadowStrength))
        key.shadowBias = 0.6
        key.automaticallyAdjustsShadowProjection = false
        key.orthographicScale = 30
        key.zNear = 1
        key.zFar = 200
        keyNode.light = key
        scene.rootNode.addChildNode(keyNode)
        light(NotebookLighting())

        ambient.type = .ambient
        ambient.intensity = 190
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // The ground that takes the book's shadow (the scrim under it is the overlay's: NotebookView).
        let groundPlane = SCNPlane(width: 600, height: 600)
        groundPlane.materials = [BookMaterials.shadowCatcher()]
        let ground = SCNNode(geometry: groundPlane)
        ground.renderingOrder = -10
        ground.castsShadow = false
        scene.rootNode.addChildNode(ground)

        scene.rootNode.addChildNode(bookNode)

        // The back board: leather all round, its inside covered by the back pastedown (a recto's way round) with the
        // leather's turn-in showing round it, as a bound book's board.
        let size = BookSize.self
        let back = SCNBox(width: CGFloat(size.boardWidth), height: CGFloat(size.boardHeight), length: CGFloat(size.board),
                          chamferRadius: 0.08)
        back.chamferSegmentCount = 3
        let backPastedown = BookMaterials.page(spineAtStart: true)
        pageMaterials[.backPastedown] = backPastedown
        back.materials = [leatherMaterial, leatherSide, leatherMaterial, leatherSide, leatherEnd, leatherEnd]
        backBoard.geometry = back
        backBoard.simdPosition = SIMD3(size.boardWidth / 2, 0, size.board / 2)
        backBoard.addChildNode(pastedown(backPastedown, inside: 1))
        bookNode.addChildNode(backBoard)

        rightStack.castsShadow = true
        bookNode.addChildNode(rightStack)

        // The front board swings about the spine with the leaves turned so far (BookGeometry: its local
        // frame is the closed book's, its outside +z).
        let front = SCNBox(width: CGFloat(size.boardWidth), height: CGFloat(size.boardHeight), length: CGFloat(size.board),
                           chamferRadius: 0.08)
        front.chamferSegmentCount = 3
        let frontPastedown = BookMaterials.page(spineAtStart: false)
        pageMaterials[.frontPastedown] = frontPastedown
        front.materials = [leatherMaterial, leatherSide, leatherMaterial, leatherSide, leatherEnd, leatherEnd]
        frontBoard.geometry = front
        frontBoard.addChildNode(pastedown(frontPastedown, inside: -1))
        let foilPlane = SCNPlane(width: CGFloat(size.boardWidth), height: CGFloat(size.boardHeight))
        foilPlane.materials = [BookMaterials.foilTitle(mask: titleMask, color: coverStyle.foilColor)]
        foil.geometry = foilPlane
        foil.castsShadow = false
        foil.simdPosition = SIMD3(0, 0, size.board / 2 + 0.004)
        frontBoard.addChildNode(foil)
        leftGroup.addChildNode(frontBoard)
        leftGroup.addChildNode(leftStack)
        bookNode.addChildNode(leftGroup)

        spine.castsShadow = true
        bookNode.addChildNode(spine)

        for leaf in 0..<leafCount {
            let recto = BookMaterials.page(spineAtStart: true), verso = BookMaterials.page(spineAtStart: false)
            pageMaterials[BookTextureKey(leaf: leaf, verso: false)] = recto
            pageMaterials[BookTextureKey(leaf: leaf, verso: true)] = verso
            let root = SCNNode(), r = SCNNode(), v = SCNNode()
            root.addChildNode(r)
            root.addChildNode(v)
            root.isHidden = true
            bookNode.addChildNode(root)
            leaves.append((root, r, v))
        }
        applyCamera()
        pose(drag: nil, dt: 0, freeze: nil)
    }

    /// A board's pastedown: page-sized paper on the inside face (+z for the back board, −z for the front), flush with
    /// the spine, so the leather shows on the other three sides. Turned to face −z it reads the verso's way round.
    private func pastedown(_ material: SCNMaterial, inside: Float) -> SCNNode {
        let size = BookSize.self
        let plane = SCNPlane(width: CGFloat(size.pageWidth - 0.1), height: CGFloat(size.pageHeight - 0.1))
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.simdPosition = SIMD3(0.05 + (size.pageWidth - 0.1) / 2 - size.boardWidth / 2, 0, inside * (size.board / 2 + 0.003))
        if inside < 0 { node.simdEulerAngles = SIMD3(0, .pi, 0) }
        return node
    }

    // MARK: - Each frame

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.lock()
        let input = pending
        pending.release = nil
        pending.tapped = nil
        pending.textures = [:]
        pending.snap = false
        pending.restartIdleDetection = false
        lock.unlock()

        if input.restartIdleDetection { quietFrames = 0 }
        if input.presentationID != presentationID {
            presentationID = input.presentationID
            reportedOpen = false
            reportedClosed = false
        }
        let dt = Float(min(1.0 / 30, max(0, time - (lastTime ?? time))))
        if input.light != litBy { light(input.light) }
        lastTime = time

        for (key, texture) in input.textures {
            if let texture { pageMaterials[key]?.diffuse.contents = texture }
            else { pageMaterials[key]?.diffuse.contents = BookMaterials.paper }
        }
        if input.layout != target {
            let turned = input.turnAnimates && !input.snap && input.layout.roll != target.roll
            let closed = flight.target == 0 && flight.value < 0.001 && turning == nil
            target = input.layout
            if turned && !closed {
                // Open (or on its way): from where the book shows now (mid-turn too) to the new layout.
                turning = (layout, 0)
                relocating = false
            } else if turned && !Self.sameOnScreen(layout, target) {
                relocating = true
            } else if turned {
                shadowTurn = shadowTurn ?? 0
            } else if !relocating {
                // Closed where it already lies on the glass (the camera's roll undone by the book's): nothing moves.
                turning = nil
                take(target)
            }
        }
        if relocating, input.open {
            // Opened on its way out: it glides to the new layout instead.
            relocating = false
            turning = (layout, 0)
        } else if relocating, stow.value > 0.995 {
            relocating = false
            take(target)
        }
        if let t = shadowTurn {
            let next = t + dt / 0.9
            if t < 0.5, next >= 0.5 { take(target) }
            shadowTurn = next < 1 ? next : nil
            if next >= 1, layout != target { take(target) }
            shade(shadowTurn.map { abs(1 - 2 * $0) } ?? 1)
        }
        if let turn = turning {
            let t = min(1, turn.t + dt / BookMotion.turn)
            turning = t < 1 ? (turn.from, t) : nil
            // Ease in and out, as SwiftUI's easeInOut (a cubic Bézier close to smoothstep).
            if t < 1 {
                layout = BookLayout.mix(turn.from, target, t * t * (3 - 2 * t))
                applyCamera()
            } else {
                take(target)
            }
        }
        step(input, dt: dt)
        pose(drag: input.drag, dt: dt, freeze: input.freeze)
        report(input, dt: dt)
    }

    private func step(_ input: BookInput, dt: Float) {
        // Opening: fly in, then the cover. Closing: settle the pages, shut the cover, then fly home.
        if input.open {
            flight.target = 1
            if flight.value > BookMotion.coverStarts || cover.target > 0 { cover.target = .pi }
            let leafAsked = input.drag != nil || angles.indices.contains { i in
                i < input.turned.count && (input.turned[i] ? Float.pi : 0) != angles[i].target
            }
            if leafAsked, cover.target == .pi, cover.value < .pi - 0.01 { cover.tune(BookMotion.coverHurry) }
        } else {
            cover.tune(BookMotion.cover)
            if angles.allSatisfy(\.settled) && input.drag == nil { cover.target = 0 }
            flight.target = cover.value < BookMotion.flightReturns * .pi && cover.target == 0 ? 0 : 1
        }
        for i in angles.indices where i < input.turned.count {
            let target: Float = input.turned[i] ? .pi : 0
            if input.tapped == i { angles[i].tune(BookMotion.tappedLeaf) }
            else if input.release?.leaf == i || angles[i].target != target { angles[i].tune(BookMotion.leaf) }
            angles[i].target = target
        }
        if let release = input.release, angles.indices.contains(release.leaf) {
            angles[release.leaf].velocity = release.velocity
        }
        if input.snap {
            flight.snap()
            cover.target = input.open ? .pi : 0
            cover.snap()
            for i in angles.indices {
                angles[i].snap()
                liesLeft[i] = i < input.turned.count && input.turned[i]
            }
        }

        if let held = input.lowered {
            lowered.value = held; lowered.target = held; lowered.velocity = 0
        } else if input.open {
            lowered.target = 0
            // A fresh opening starts from the middle.
            if flight.value < 0.01 { lowered.snap() }
            lowered.step(dt)
        }
        stow.target = (input.stowed || relocating) && !input.open ? 1 : 0
        // Stowed from the start (behind the splash): already off the screen.
        if !stowStarted { stowStarted = true; stow.value = stow.target }
        stow.step(dt)
        press.target = input.pressed && !input.open ? 1 : 0
        press.step(dt)
        flight.step(dt)
        cover.step(dt)
        if cover.value >= .pi { cover.value = .pi; cover.velocity = min(0, cover.velocity) }
        if cover.value <= 0 { cover.value = 0; cover.velocity = max(0, cover.velocity) }
        for i in angles.indices {
            if let drag = input.drag, drag.leaf == i {
                // The finger leads; the binding follows a touch behind it.
                let previous = angles[i].value
                angles[i].value += (drag.angle - previous) * (1 - exp(-dt * 24))
                angles[i].velocity = dt > 0 ? (angles[i].value - previous) / dt : 0
            } else {
                angles[i].step(dt)
                if angles[i].value <= 0 { angles[i].value = 0; angles[i].velocity = max(0, angles[i].velocity) }
                if angles[i].value >= .pi { angles[i].value = .pi; angles[i].velocity = min(0, angles[i].velocity) }
            }
        }

        frozenLeaf = nil
        switch input.freeze {
        case .turn(let degrees)?:
            if let leaf = input.turned.firstIndex(of: false), cover.value >= .pi - 0.001 {
                angles[leaf].value = degrees * .pi / 180
                angles[leaf].velocity = 0
                frozenLeaf = leaf
            }
        case .cover(let degrees)?:
            flight.value = 1; flight.velocity = 0
            cover.value = degrees * .pi / 180; cover.velocity = 0
        case .flight(let value)?:
            flight.value = value; flight.velocity = 0
            cover.value = 0; cover.velocity = 0
        case nil:
            break
        }
    }

    private func report(_ input: BookInput, dt: Float) {
        let still = turning == nil && !relocating && shadowTurn == nil && press.settled && flight.settled && stow.settled && (lowered.settled || !input.open) && input.lowered == nil && cover.settled && angles.allSatisfy(\.settled) && input.drag == nil
        quietFrames = still ? quietFrames + 1 : 0
        var events: [BookEvent] = []
        // Open for the hand as soon as the book has arrived and its cover is a third over (waiting for the
        // cover's last settle made the pages feel slow); a page turned then hurries the cover (`step`).
        if input.open, flight.value > 0.9, cover.value > BookMotion.openForHand * .pi, !reportedOpen {
            reportedOpen = true
            reportedClosed = false
            events.append(.opened)
        }
        if !input.open, flight.value < 0.002, cover.value < 0.01, !reportedClosed {
            reportedClosed = true
            reportedOpen = false
            events.append(.closed)
        }
        if !input.open, flyingOut, flight.target == 0 { events.append(.homeward) }
        flyingOut = flight.target == 1
        if quietFrames == 3 { events.append(.idle) }
        // The sounds hear the motion; a jump (snap) is silent.
        for i in angles.indices {
            soundTracker.leaf(i, angle: angles[i].value, velocity: angles[i].velocity, target: angles[i].target,
                              held: input.drag?.leaf == i)
        }
        soundTracker.book(cover: cover.value, coverVelocity: cover.velocity, coverTarget: cover.target, flight: flight.value,
                          flightVelocity: flight.velocity, flightTarget: flight.target, stowVelocity: stow.velocity,
                          lowered: input.lowered, dt: dt)
        soundTracker.finish(into: soundFeed, snap: input.snap)
        guard !events.isEmpty else { return }
        Task { @MainActor [controller] in
            for event in events { controller?.renderer(reported: event) }
        }
    }

    /// Lights the book as the garden is lit: the key light comes from the garden's light direction (its y turned up, the
    /// book's world being y-up), its shadow as strong as the garden's cast shadows, its colour the garden's tint; the
    /// fill follows the day.
    private func light(_ l: NotebookLighting) {
        litBy = l
        placeKey()
        shade(1)
        key.intensity = CGFloat(720 * min(max(l.strength, 0.2), 1.2))
        key.color = UIColor(red: CGFloat(min(l.tint.x, 1)), green: CGFloat(min(l.tint.y, 1)), blue: CGFloat(min(l.tint.z, 1)), alpha: 1)
        ambient.intensity = CGFloat(190 * min(max(l.fill, 0.3), 1))
    }

    // MARK: - Placing everything

    /// The key light where the garden's is: in the holder's frame (the ground's), as the scenery's light turns with
    /// the holding (the host lighting transition).
    private func placeKey() {
        guard let l = litBy else { return }
        let toLight = simd_normalize(SIMD3(l.direction.x, -l.direction.y, max(l.direction.z, 0.05)))
        keyNode.simdPosition = toLight * 80
        keyNode.simdLook(at: .zero, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    }

    /// The shadow at the garden's strength, times `share` (a turn's fade).
    private func shade(_ share: Float) {
        let strength = min(max(litBy?.shadow ?? 1, 0), 1)
        key.shadowColor = UIColor(white: 0, alpha: CGFloat(Self.shadowStrength * strength * share))
    }

    /// Shows `layout` at once (the cover's title printed for its edge).
    private func take(_ new: BookLayout) {
        if new.titleTurned != layout.titleTurned {
            foil.geometry?.firstMaterial?.transparent.contents = new.titleTurned
                ? titleMaskTurned : titleMask
        }
        layout = new
        applyCamera()
    }

    /// The closed book lies in the same place on the glass, turned the same way, in both layouts (within a point).
    private static func sameOnScreen(_ a: BookLayout, _ b: BookLayout) -> Bool {
        func onGlass(_ p: SIMD2<Float>, _ roll: Float) -> SIMD2<Float> {
            SIMD2(p.x * cos(roll) + p.y * sin(roll), -p.x * sin(roll) + p.y * cos(roll))
        }
        let place = simd_distance(onGlass(a.compactCenter, a.roll), onGlass(b.compactCenter, b.roll)) / a.unitsPerPoint
        let turn = abs(remainder((a.compactRoll - a.roll) - (b.compactRoll - b.roll), 2 * .pi))
        return place < 1 && turn < 0.01 && abs(a.compactScale - b.compactScale) < 0.001
    }

    private func applyCamera() {
        let height = layout.viewHeight * layout.unitsPerPoint
        cameraNode.camera?.fieldOfView = CGFloat(2 * atan(height / 2 / layout.cameraDistance) * 180 / .pi)
        cameraNode.simdPosition = SIMD3(0, 0, layout.cameraDistance)
        cameraNode.simdOrientation = simd_quatf(angle: layout.roll, axis: SIMD3(0, 0, 1))
    }

    private func pose(drag: BookDrag?, dt: Float, freeze: BookFreeze?) {
        let size = BookSize.self
        let motion = BookMotion.self
        let b = size.board
        let leafThickness = size.block / Float(leafCount)
        let alpha = cover.value
        let opened = smooth(alpha / .pi)
        let p = max(0, flight.value)

        // The book in the world: from the corner it rises over the garden to the middle, tipping on the way, and
        // floats there tipped back a little; as it opens it moves from its cover centred to its spine where the layout
        // puts it.
        let scale = exp(mix(log(layout.compactScale), log(layout.largeScale), min(1, p)))
            * mix(1, motion.stowScale, stow.value) * (1 - motion.pressDepth * press.value * (1 - min(1, p)))
        let roll = mix(layout.compactRoll, 0, min(1, p))
        let arc = sin(.pi * min(1, p))
        let settled = smooth(p)
        let height = motion.openLift * settled + motion.flightArc * arc
        let tip = motion.openTilt * settled + motion.flightTip * arc
        let centre = mix(layout.compactCenter + layout.compactStow * stow.value, layout.largeCenter, min(1, p))
        let rotation = simd_quatf(angle: roll, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: -tip, axis: SIMD3(1, 0, 0))
        let closedOrigin = SIMD3(centre, height) - rotation.act(SIMD3(size.boardWidth / 2 * scale, 0, 0))
        let origin = mix(closedOrigin, SIMD3(layout.openSpine, height), opened)
        // Pulled down: down the screen, a little smaller, all of it gone by the time the book is home.
        let pull = lowered.value * layout.unitsPerPoint * min(1, p)
        let shrink = 1 - min(0.12, lowered.value / 1800) * min(1, p)
        let pulled = origin - SIMD3(0, pull, 0)
        bookNode.simdTransform = simd_float4x4(translation: pulled) * simd_float4x4(rotation) * simd_float4x4(scale: scale * shrink)

        // The leaves in the air (only in the open book) are those turning: under a finger, on their way, or sent back;
        // the rest lie in the stacks.
        let canFly = opened > 0.999
        let wantsAir = { (i: Int) -> Bool in
            canFly && (drag?.leaf == i || i == self.frozenLeaf || !self.angles[i].settled
                       || (self.angles[i].target > .pi / 2) != self.liesLeft[i])
        }
        var restRight = 0, restLeft = 0
        var topRight: Int?, topLeft: Int?
        for i in 0..<leafCount where !wantsAir(i) {
            if liesLeft[i] { restLeft += 1; topLeft = i } else { restRight += 1; if topRight == nil { topRight = i } }
        }
        let tR = Float(restRight) * leafThickness, tL = Float(restLeft) * leafThickness
        // The pages in the air hand their thickness over as they go: the stack a page leaves thins as it lifts (the
        // first two thirds of its turn), the one it comes to thickens as it comes down (the last two thirds).
        var extraR: Float = 0, extraL: Float = 0
        for i in 0..<leafCount where wantsAir(i) {
            let q = max(0, min(1, angles[i].value / .pi))
            extraR += (1 - smooth(q / 0.65)) * leafThickness
            extraL += smooth((q - 0.35) / 0.65) * leafThickness
        }
        let topR = b + tR, topL = b + tL
        // The root is deep in the binding, at the boards: each page climbs out of the gutter to its stack's top.
        let root = b + 0.03
        let riseR = max(0, topR - root) * opened, riseL = max(0, topL - root) * opened
        let rootR = topR - riseR, rootL = topL - riseL

        let rightCurve = BookCurve.rest(left: false, root: SIMD2(0, rootR), rise: riseR)
        rightStack.isHidden = restRight == 0
        let rightShape = BookShape(rightCurve, extra: extraR)
        if restRight > 0, rightShape != rightStackShape {
            rightStackShape = rightShape
            rightStack.geometry = BookMesh.stack(top: rightCurve, floor: b, extra: extraR)
            rightStack.geometry?.materials = [edgeMaterial]
        }

        // The front board and the left stack swing about the spine. In their own frame the closed book's: open-world
        // shapes (x < 0) map by (x, z) → (−x, b + tL − z).
        let hinge = mix(b + tR, b + tL, opened)
        leftGroup.simdTransform = simd_float4x4(translation: SIMD3(0, 0, hinge)) * simd_float4x4(simd_quatf(angle: -alpha, axis: SIMD3(0, 1, 0)))
        frontBoard.simdPosition = SIMD3(size.boardWidth / 2, 0, tL + b / 2)
        let toLocal: (SIMD2<Float>) -> SIMD2<Float> = { SIMD2(-$0.x, b + tL - $0.y) }
        let flip: (SIMD2<Float>) -> SIMD2<Float> = { -$0 }
        let leftCurve = BookCurve.rest(left: true, root: SIMD2(0, rootL), rise: riseL)
        leftStack.isHidden = restLeft == 0
        let leftShape = BookShape(leftCurve, extra: extraL, local: tL)
        if restLeft > 0, leftShape != leftStackShape {
            leftStackShape = leftShape
            leftStack.geometry = BookMesh.stack(top: leftCurve, floor: b, extra: extraL, transform: toLocal,
                                                     normalTransform: flip)
            leftStack.geometry?.materials = [edgeMaterial]
        }

        // The spine, from the back board's spine edge to the front board's.
        let reach = tL + b
        let frontEdge = SIMD2(-reach * sin(alpha), hinge + reach * cos(alpha))
        if SIMD3(frontEdge, alpha) != spineShape {
            spineShape = SIMD3(frontEdge, alpha)
            spine.geometry = BookMesh.spine(from: .zero, to: frontEdge, bulge: SIMD2(-cos(alpha / 2), -sin(alpha / 2)))
            spine.geometry?.materials = [spineMaterial, headband]
        }

        // A turning page lies on top of the stacks: its resting shapes there, and the floor it cannot pass.
        let flyRiseR = max(0, topR + leafThickness - root), flyRiseL = max(0, topL + leafThickness - root)
        let flyRight = BookCurve.rest(left: false, root: SIMD2(0, root), rise: flyRiseR)
        let flyLeft = BookCurve.rest(left: true, root: SIMD2(0, root), rise: flyRiseL)
        // Nearly a whole leaf above the top leaves (the same stacked shapes): a turning page never cuts through the
        // page beneath it.
        let rightFloor = BookCurve.rest(left: false, root: SIMD2(0, root),
                                             rise: max(0, topR + 0.92 * leafThickness - root)).points
        let leftFloor = BookCurve.rest(left: true, root: SIMD2(0, root),
                                            rise: max(0, topL + 0.92 * leafThickness - root)).points
        let floor = { (x: Float) -> Float in
            let line = x >= 0 ? rightFloor : leftFloor
            let reach = abs(x)
            guard let last = line.last, reach < abs(last.x) else { return b }
            for k in 1..<line.count where abs(line[k].x) >= reach {
                let a = line[k - 1], c = line[k]
                let t = (reach - abs(a.x)) / max(abs(c.x) - abs(a.x), 1e-5)
                return a.y + (c.y - a.y) * t
            }
            return b
        }
        var turning: [Int: BookCurve] = [:]
        for i in 0..<leafCount where wantsAir(i) {
            turning[i] = BookCurve.fold(progress: angles[i].value / .pi, right: flyRight, left: flyLeft,
                                             radius: motion.foldRadius, floor: floor)
            // Its turn has arrived: it lies exactly in its resting shape, and from the next frame it is its stack's top.
            if drag?.leaf != i, i != frozenLeaf, angles[i].settled { liesLeft[i] = angles[i].target > .pi / 2 }
        }

        // The leaves: the two on top of the stacks and those in the air; the rest are inside the stacks.
        for i in 0..<leafCount {
            if let curve = turning[i] {
                place(i, in: bookNode, curve: curve, shape: BookShape(curve))
            } else if i == topRight {
                place(i, in: bookNode, curve: rightCurve, shape: BookShape(rightCurve))
            } else if i == topLeft {
                place(i, in: leftGroup, curve: leftCurve, shape: BookShape(leftCurve, local: tL), transform: toLocal,
                      normalTransform: flip)
            } else {
                leaves[i].root.isHidden = true
            }
        }
    }

    /// Which page a hit node is (a leaf's recto or verso), for a finger on the page.
    func pageKey(of node: SCNNode) -> BookTextureKey? {
        for (i, leaf) in leaves.enumerated() {
            if node === leaf.recto { return BookTextureKey(leaf: i, verso: false) }
            if node === leaf.verso { return BookTextureKey(leaf: i, verso: true) }
        }
        return nil
    }

    private func place(_ leaf: Int, in parent: SCNNode, curve: BookCurve, shape: BookShape,
                       transform: @escaping (SIMD2<Float>) -> SIMD2<Float> = { $0 },
                       normalTransform: @escaping (SIMD2<Float>) -> SIMD2<Float> = { $0 }) {
        let node = leaves[leaf]
        if node.root.parent !== parent { parent.addChildNode(node.root) }
        node.root.isHidden = false
        guard shape != leafShapes[leaf] else { return }
        leafShapes[leaf] = shape
        let recto = BookMesh.leafFace(curve, verso: false, transform: transform, normalTransform: normalTransform)
        recto.materials = [pageMaterials[BookTextureKey(leaf: leaf, verso: false)]!]
        let verso = BookMesh.leafFace(curve, verso: true, transform: transform, normalTransform: normalTransform)
        verso.materials = [pageMaterials[BookTextureKey(leaf: leaf, verso: true)]!]
        // The left group's map turns (x, z) half round (it does not mirror), so the windings hold.
        node.recto.geometry = recto
        node.verso.geometry = verso
    }
}

/// What a mesh is built from: a curve, the thickness of pages on their way (a stack's `extra`), and the left stack's
/// depth its own frame is measured from (nil: built in the book's frame).
private struct BookShape: Equatable {
    let points: [SIMD2<Float>]
    let normals: [SIMD2<Float>]
    var extra: Float = 0
    var local: Float?

    init(_ curve: BookCurve, extra: Float = 0, local: Float? = nil) {
        points = curve.points
        normals = curve.normals
        self.extra = extra
        self.local = local
    }
}

private func smooth(_ t: Float) -> Float {
    let x = max(0, min(1, t))
    return x * x * (3 - 2 * x)
}

private func mix<T: SIMD>(_ a: T, _ b: T, _ t: Float) -> T where T.Scalar == Float { a + (b - a) * t }
private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

private extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }
    init(scale s: Float) {
        self = simd_float4x4(diagonal: SIMD4(s, s, s, 1))
    }
}
#endif
