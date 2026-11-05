#if os(iOS)
import MetalKit
import SceneKit
import SwiftUI
import UIKit
import simd

/// The edge the closed book lies past.
public enum NotebookEdge: Equatable { case bottom, top, left, right }

/// Where the toolbar stands and the closed book lies where the toolbar isn't the iPhone's top band (the Duo's rail or
/// column, a large screen's corners), in the holder's frame: NotebookPlacement.
public struct NotebookPlacement: Equatable {
    /// The icons' 44-pt frames, where the open book's ✕ and ≡ stand (the toolbar's own places): the open book keeps
    /// clear of them.
    public var icons: [CGRect]
    /// They stand one above the other at a side (the Duo's rail or column), not along the top.
    public var column: Bool
    /// The edge the closed book lies past and its middle along that edge (points); nil: the controller's own rules.
    public var compactEdge: NotebookEdge?
    public var compactAlong: CGFloat = 0
    /// The open spread's crease on the screen's middle (a large screen held wide: on the Duo's inner display, its
    /// fold), the spread smaller rather than off-centre.
    public var creaseCentred = false
    /// An iPad (and the Mac): more air round the open book, as much under it as over it ("very large").
    public var roomy = false
    public init(icons: [CGRect] = [], column: Bool = false, compactEdge: NotebookEdge? = nil,
                compactAlong: CGFloat = 0, creaseCentred: Bool = false, roomy: Bool = false) {
        self.icons = icons
        self.column = column
        self.compactEdge = compactEdge
        self.compactAlong = compactAlong
        self.creaseCentred = creaseCentred
        self.roomy = roomy
    }
}

final class BookSceneView: SCNView {
    weak var controller: NotebookController?
    var safeInsets = UIEdgeInsets.zero
    var place: NotebookPlacement?
    /// How the holder holds the phone, in quarter turns (NotebookView.quarterTurns): the controller works in the
    /// holder's frame (the screen turned to face them, its sides swapped when sideways), this view in the screen's.
    var turns = 0
    var turnAnimates = true

    /// The view's size as the holder sees it.
    var heldSize: CGSize { turns == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width) }

    /// A point on the screen in the holder's frame (content turned clockwise for +1: the holder's top is the screen's
    /// right).
    func held(_ point: CGPoint) -> CGPoint {
        switch turns {
        case 1: CGPoint(x: point.y, y: bounds.width - point.x)
        case -1: CGPoint(x: bounds.height - point.y, y: point.x)
        default: point
        }
    }

    /// A point in the holder's frame on the screen.
    func screen(_ point: CGPoint) -> CGPoint {
        switch turns {
        case 1: CGPoint(x: bounds.width - point.y, y: point.x)
        case -1: CGPoint(x: point.y, y: bounds.height - point.x)
        default: point
        }
    }

    /// A movement on the screen (a pan's translation or velocity) in the holder's frame.
    private func held(vector v: CGPoint) -> CGPoint {
        switch turns {
        case 1: CGPoint(x: v.y, y: -v.x)
        case -1: CGPoint(x: -v.y, y: v.x)
        default: v
        }
    }
    func installGestures() {
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        controller?.tap(at: held(gesture.location(in: self)))
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        controller?.pan(gesture.state, translation: held(vector: gesture.translation(in: self)),
                        velocity: held(vector: gesture.velocity(in: self)))
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .changed, gesture.scale < 0.82 { controller?.close() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = heldSize
        controller?.layout(size: size, insets: safeInsets, place: place, turns: turns, screenHeight: bounds.height,
                           animated: turnAnimates)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.press(true)
        super.touchesBegan(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.press(false)
        super.touchesEnded(touches, with: event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.press(false)
        super.touchesCancelled(touches, with: event)
    }

    /// Closed in the corner the book takes only the touches on it; the garden keeps the rest.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        controller?.takesTouch(at: held(point)) ?? false
    }
}

@MainActor @Observable
public final class NotebookController {
    public enum Mode { case compact, opening, open, closing }

    public private(set) var mode: Mode = .compact
    /// Page sounds default to off; the host owns AVAudioSession policy.
    public var soundEnabled = false {
        didSet { sounds.enabled = soundEnabled }
    }
    public func setLighting(_ lighting: NotebookLighting) {
        renderer.update { $0.light = lighting }
        wake(moving: false)
    }

    /// Not needed now: closed, the book steps off the screen (NotebookController.stowed).
    public var stowed = false {
        didSet {
            guard stowed != oldValue else { return }
            renderer.update { $0.stowed = self.stowed }
            wake()
        }
    }
    /// The scrim is over the garden: from the tap that opens the book until, closed, it starts home.
    public private(set) var dims = false

    /// The open book has the status bar's slot (its ✕), from the tap that opens it to the one that closes it.
    public var isOpen: Bool { mode == .opening || mode == .open }

    @ObservationIgnored private let renderer: NotebookRenderer
    @ObservationIgnored private weak var view: BookSceneView?
    @ObservationIgnored private let leafCount: Int
    @ObservationIgnored private let document: NotebookDocument
    /// The leaves lying left, and how many: the spread shows leaf `spread − 1`'s verso and leaf `spread`'s recto.
    @ObservationIgnored private var turned: [Bool]
    public private(set) var spread = 0
    /// The book's own sounds, played from its motion (the renderer's sound feed).
    @ObservationIgnored private let sounds: BookSounds
    @ObservationIgnored private var size = CGSize.zero
    @ObservationIgnored private var insets = UIEdgeInsets.zero
    @ObservationIgnored private var bookLayout = BookLayout()
    @ObservationIgnored private var pageLoad: Task<Void, Never>?
    /// Pages become GPU textures here with every mipmap made, before SceneKit sees them: a texture SceneKit uploads and
    /// mipmaps by itself shows half-made for a few frames (bands of a page missing) whenever a page comes back.
    @ObservationIgnored private var textureLoader: MTKTextureLoader?
    /// The pages photographed, and how many pixels wide.
    @ObservationIgnored private var loaded: [BookTextureKey: CGFloat] = [:]
    /// How wide the pages at rest on the open book are photographed: as many pixels as they show across (a large
    /// screen's pages are soft at NotebookPage.pixelWidth), up to 2048; NotebookPage.pixelWidth where that is
    /// within 15 % (the iPhone's), and for every page not at rest (seen only turning).
    @ObservationIgnored private var sharpWidth = NotebookPage.pixelWidth
    @ObservationIgnored private var drag: (leaf: Int, forward: Bool)?
    /// Nothing in the book is moving (the renderer reported it idle): the pages that can wait are photographed then,
    /// not while a page turns or the book flies (each holds the main thread for tens of milliseconds).
    @ObservationIgnored private var still = true
    @ObservationIgnored private var active = true
    @ObservationIgnored private var riffle: Task<Void, Never>?

    public init(document: NotebookDocument, cover: NotebookCover = NotebookCover()) {
        self.document = document
        leafCount = document.leaves.count
        turned = Array(repeating: false, count: document.leaves.count)
        renderer = NotebookRenderer(leafCount: document.leaves.count, cover: cover)
        sounds = BookSounds(feed: renderer.soundFeed)
        renderer.controller = self
        sounds.enabled = false
    }

    func attach(_ view: BookSceneView) {
        self.view = view
        view.controller = self
        view.scene = renderer.scene
        view.pointOfView = renderer.cameraNode
        view.delegate = renderer
        view.backgroundColor = .clear
        view.isOpaque = false
        view.layer.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 120
        view.isPlaying = false
        view.installGestures()

        if mode != .compact { loadPages() }
        wake(moving: mode != .compact)
    }

    func detach(_ view: BookSceneView) {
        guard self.view === view else { return }
        pageLoad?.cancel()
        riffle?.cancel()
        view.isPlaying = false
        view.delegate = nil
        view.controller = nil
        self.view = nil
        sounds.suspend()
    }

    var accessibilitySummary: String {
        guard isOpen else { return "Notebook. Double tap to open." }
        let right = spread < leafCount ? document.leaves[spread].recto : document.backInsideCover
        let left = spread > 0 ? document.leaves[spread - 1].verso : document.frontInsideCover
        return sideways ? left.accessibilityLabel + ". " + right.accessibilityLabel : right.accessibilityLabel
    }

    /// Re-render nearby faces after the data captured by page builders changes.
    public func invalidatePages() {
        loaded.removeAll()
        if mode != .compact { loadPages() }
    }

    /// Pause drawing/audio while the host scene is inactive.
    public func setActive(_ active: Bool) {
        self.active = active
        if active {
            if mode != .compact { loadPages() }
            wake(moving: mode != .compact)
        }
        else {
            pageLoad?.cancel()
            riffle?.cancel()
            view?.isPlaying = false
            sounds.suspend()
        }
    }

    // MARK: - Layout

    /// The ground's scale (cm per point) and where the book lies closed, held large and open, for this view. `place`:
    /// where the toolbar stands where it isn't the iPhone's top band (NotebookPlacement).
    /// `size`, `insets` and `place` are in the holder's frame; `turns`: how the screen is turned to face them (the
    /// camera rolls with it), `screenHeight`: the view's own height (the camera's), `animated`: the book glides there.
    func layout(size: CGSize, insets: UIEdgeInsets, place: NotebookPlacement?, turns: Int = 0, screenHeight: CGFloat? = nil,
                animated: Bool = false) {
        guard size.width > 0, size.height > 0,
              size != self.size || insets != self.insets || place != self.place || turns != self.turns else { return }
        if turns != self.turns { still = false }
        self.turns = turns
        self.size = size
        self.insets = insets
        self.place = place
        let u: Float = 0.05
        let w = Float(size.width), h = Float(size.height)
        func ground(_ x: Float, _ y: Float) -> SIMD2<Float> { SIMD2((x - w / 2) * u, (h / 2 - y) * u) }
        let sideways = w > h
        var layout = BookLayout()
        layout.viewHeight = Float(screenHeight ?? size.height)
        layout.roll = Float(turns) * .pi / 2
        layout.unitsPerPoint = u
        // The open book floats nearer the camera than the ground: it fits once that nearness is taken off.
        let near = Self.nearness(layout)
        // The middle of the safe width, and of the height.
        let middle = SIMD2(Float(insets.left) + (w - Float(insets.left + insets.right)) / 2, h / 2)
        // Closed: most of it past an edge, its spine turned in, so the band along the spine shows, with 庭の図鑑
        // (BookMaterials.titleMask), and a little of the board beyond it. On iPhone, upright it lies on its side
        // along the bottom edge, in the middle of the safe width; sideways it stands at the side away from the icons
        // (they stand along the camera's side, the larger inset), in the middle of the height. Elsewhere where `place`
        // puts it. 200 pt long.
        layout.compactScale = Self.compactLength * u / BookSize.boardHeight
        let depth = Self.compactLength * BookSize.boardWidth / BookSize.boardHeight
        let past = depth * (Self.compactHidden - 0.5)
        let along: Float
        if let edge = place?.compactEdge, let place {
            compactEdge = edge
            along = Float(place.compactAlong)
        } else if !sideways {
            compactEdge = .bottom
            along = middle.x
        } else {
            compactEdge = insets.left >= insets.right ? .right : .left
            along = middle.y
        }
        let corner: SIMD2<Float>
        switch compactEdge {
        case .bottom:
            layout.compactRoll = -.pi / 2
            corner = SIMD2(along, h + past)
        case .top:
            // Its spine down: the title band is printed turned to read level from here (BookMaterials.titleMask).
            layout.compactRoll = .pi / 2
            layout.titleTurned = true
            corner = SIMD2(along, -past)
        case .right:
            layout.compactRoll = 0
            corner = SIMD2(w + past, along)
        case .left:
            layout.compactRoll = .pi
            corner = SIMD2(-past, along)
        }
        layout.compactCenter = ground(corner.x, corner.y)
        // Stowed, it moves out past its edge by what shows of it, its shadow and the perspective's few points, and on
        // (BookMotion.stowReach).
        let clear = (depth * (1 - Self.compactHidden) + 40) * u * BookMotion.stowReach
        switch compactEdge {
        case .bottom: layout.compactStow = SIMD2(0, -clear)
        case .top: layout.compactStow = SIMD2(0, clear)
        case .right: layout.compactStow = SIMD2(clear, 0)
        case .left: layout.compactStow = SIMD2(-clear, 0)
        }
        let board = SIMD2(BookSize.boardWidth, BookSize.boardHeight)
        if let place {
            // Where the toolbar isn't the iPhone's (Jip, 3 Nov, on the Duo: never under its icons): as large as fits
            // in the safe area clear of the icons, in the middle of the room left. Sideways the height is the whole
            // view's (the outer display's rail is only sand by then; its icons stand along the camera's side).
            let room = sideways ? CGRect(x: insets.left, y: 0, width: size.width - insets.left - insets.right, height: size.height)
                : CGRect(x: insets.left, y: insets.top, width: size.width - insets.left - insets.right,
                         height: size.height - insets.top - insets.bottom)
            let gap: CGFloat = 12
            let icons = place.icons.reduce(CGRect.null) { $0.union($1) }
            var rooms = [room]
            if !icons.isNull {
                if place.column {
                    // The column's side.
                    let edge = icons.midX > size.width / 2 ? min(room.maxX, icons.minX - gap) : max(room.minX, icons.maxX + gap)
                    rooms = [icons.midX > size.width / 2 ? CGRect(x: room.minX, y: room.minY, width: edge - room.minX, height: room.height)
                             : CGRect(x: edge, y: room.minY, width: room.maxX - edge, height: room.height)]
                } else {
                    // Along the top: below the icons (on iPad as much room left under the book as over it, so it isn't
                    // tight against the bottom: Jip, 3 Nov), or between them, whichever holds the larger book.
                    let top = max(room.minY, icons.maxY + gap)
                    let bottom = place.roomy ? min(room.maxY, size.height - top) : room.maxY
                    let left = place.icons.min { $0.midX < $1.midX }!, right = place.icons.max { $0.midX < $1.midX }!
                    let minX = max(room.minX, left.maxX + gap), maxX = min(room.maxX, right.minX - gap)
                    rooms = [CGRect(x: room.minX, y: top, width: room.width, height: bottom - top),
                             CGRect(x: minX, y: room.minY, width: maxX - minX, height: room.height)]
                }
            }
            if place.creaseCentred && sideways {
                // The crease on the middle: each room as wide either side of it as its nearer side allows.
                rooms = rooms.map { room in
                    let half = max(0, min(size.width / 2 - room.minX, room.maxX - size.width / 2))
                    return CGRect(x: size.width / 2 - half, y: room.minY, width: 2 * half, height: room.height)
                }
            }
            // The spread fits the height and the width with a margin round it, on iPad a share of its short side (6 %,
            // about 60 pt on the 13-inch); upright, the right-hand page.
            let pad: Float = place.roomy ? (0.06 * Float(min(size.width, size.height))).rounded() : 12
            func fit(_ room: CGRect) -> Float {
                let width = Float(room.width), height = Float(room.height)
                return sideways ? min((height - 2 * pad) * u / board.y, (width - 2 * max(16, pad)) * u / (2 * board.x))
                    : min((width - 2 * max(14, pad)) * u / board.x, (height - 2 * max(24, pad)) * u / board.y)
            }
            let best = rooms.max { fit($0) < fit($1) } ?? room
            layout.largeScale = max(0.01, fit(best) / near)
            // Its middle where it shows (nearer the camera, it shows larger about the view's middle).
            let shown = ground(w / 2 + (Float(best.midX) - w / 2) / near, h / 2 + (Float(best.midY) - h / 2) / near)
            layout.largeCenter = shown
            layout.openSpine = sideways ? shown : shown - SIMD2(board.x / 2 * layout.largeScale, 0)
        } else if sideways {
            // The spread fits the height (and the safe width), its spine in the middle.
            let byHeight = (h - 24) * u / board.y
            let byWidth = (w - Float(insets.left + insets.right) - 32) * u / (2 * board.x)
            layout.largeScale = max(0.01, min(byHeight, byWidth) / near)
            layout.largeCenter = ground(middle.x, middle.y)
            layout.openSpine = layout.largeCenter
        } else {
            // The right-hand page fills the width (its spine at the left edge), clear of the status bar.
            let byWidth = (w - 28) * u / board.x
            let byHeight = (h - Float(insets.top + insets.bottom) - 96) * u / board.y
            layout.largeScale = max(0.01, min(byWidth, byHeight) / near)
            layout.largeCenter = ground(middle.x, middle.y + 8)
            layout.openSpine = layout.largeCenter - SIMD2(board.x / 2 * layout.largeScale, 0)
        }
        bookLayout = layout
        let shown = rightPage.width * (view?.traitCollection.displayScale ?? 2)
        sharpWidth = shown > NotebookPage.pixelWidth * 1.15
            ? min(2048, (shown / 128).rounded(.up) * 128) : NotebookPage.pixelWidth
        renderer.update { $0.layout = layout; $0.turnAnimates = animated }
        if mode != .compact { loadPages() }
        wake(moving: false)
    }

    /// How much larger than on the ground the open page shows (it floats nearer the camera).
    private static func nearness(_ layout: BookLayout) -> Float {
        let height = BookMotion.openLift + BookSize.board + BookSize.block / 2
        return layout.cameraDistance / (layout.cameraDistance - height)
    }

    /// How much of the closed book's width lies past the edge: all but the band along the spine and a little board
    /// (the book's thickness, seen in perspective at the edge, pushes its face a few points further out).
    static let compactHidden: Float = 0.62
    /// The closed book's length (points), and, standing in a corner (the Duo: NotebookPlacement), how far
    /// its end keeps from the screen's end (clear of the rounded corner).
    nonisolated static let compactLength: Float = 200
    nonisolated static let compactCornerGap: CGFloat = 60

    /// The edge the closed book lies past.
    @ObservationIgnored private var compactEdge = NotebookEdge.bottom
    @ObservationIgnored private var place: NotebookPlacement?
    @ObservationIgnored private var turns = 0

    /// The closed book's touch area at its edge: what shows of it, a little more round it, at least 44 pt deep.
    private var compactRect: CGRect {
        let u = bookLayout.unitsPerPoint
        let centre = CGPoint(x: CGFloat(bookLayout.compactCenter.x / u) + size.width / 2,
                             y: size.height / 2 - CGFloat(bookLayout.compactCenter.y / u))
        let length = CGFloat(BookSize.boardHeight * bookLayout.compactScale / u)
        let reach = max(CGFloat(BookSize.boardWidth * bookLayout.compactScale / u) * CGFloat(1 - Self.compactHidden) + 12, 44)
        switch compactEdge {
        case .bottom:
            return CGRect(x: centre.x - length / 2 - 8, y: size.height - reach, width: length + 16, height: reach)
        case .top:
            return CGRect(x: centre.x - length / 2 - 8, y: 0, width: length + 16, height: reach)
        case .right:
            return CGRect(x: size.width - reach, y: centre.y - length / 2 - 8, width: reach, height: length + 16)
        case .left:
            return CGRect(x: 0, y: centre.y - length / 2 - 8, width: reach, height: length + 16)
        }
    }

    /// The open right-hand page in the view's points (the perspective's few per cent ignored).
    private var rightPage: CGRect {
        let u = bookLayout.unitsPerPoint, s = bookLayout.largeScale
        let spine = CGPoint(x: CGFloat(bookLayout.openSpine.x / u) + size.width / 2,
                            y: size.height / 2 - CGFloat(bookLayout.openSpine.y / u))
        let width = CGFloat(BookSize.pageWidth * s / u), height = CGFloat(BookSize.pageHeight * s / u)
        let page = CGRect(x: spine.x, y: spine.y - height / 2, width: width, height: height)
        // Nearer the camera: larger about the view's middle.
        let near = CGFloat(Self.nearness(bookLayout)), middle = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGRect(x: middle.x + (page.minX - middle.x) * near, y: middle.y + (page.minY - middle.y) * near,
                      width: page.width * near, height: page.height * near)
    }

    private var sideways: Bool { size.width > size.height }

    /// A finger down on the closed book (it takes only the touches on it then): it gives a little under it.
    func press(_ down: Bool) {
        guard !down || mode == .compact else { return }
        renderer.update { $0.pressed = down }
        wake(moving: false)
    }

    func takesTouch(at point: CGPoint) -> Bool {
        mode != .compact || (!stowed && compactRect.contains(point))
    }

    // MARK: - Opening and closing

    public func open() {
        guard mode == .compact || mode == .closing else { return }
        mode = .opening
        dims = true
        renderer.update { $0.open = true; $0.presentationID &+= 1; $0.turned = self.turned }
        // What has been met since the book last opened: its pages are photographed again.
        loaded.removeAll()
        loadPages()
        wake()
    }

    public func close() {
        guard mode == .open || mode == .opening else { return }
        riffle?.cancel()
        mode = .closing
        if let drag {
            // A page under the finger falls back where it came from.
            renderer.update { $0.drag = nil; $0.release = (drag.leaf, 0) }
            self.drag = nil
        }
        renderer.update { $0.open = false; $0.turned = self.turned }
        wake()
    }

    func renderer(reported event: BookEvent) {
        switch event {
        case .opened: if mode == .opening { mode = .open }
        case .homeward: if mode == .closing { dims = false }
        case .closed:
            if mode == .closing {
                dims = false
                mode = .compact
                releasePages()
            }
        case .idle:
            still = true
            if drag == nil {
                view?.isPlaying = false
                sounds.rest()
            }
        }
    }

    /// The book draws again; `moving`: something will move, and its sounds wake too (a new light, layout or page picture
    /// moves nothing).
    private func wake(moving: Bool = true) {
        guard active, view != nil else { return }
        renderer.update { _ in } // Re-arm idle detection after layout, attachment or content changes.
        view?.isPlaying = true
        if moving {
            still = false
            sounds.wake()
        }
    }

    // MARK: - Turning

    /// One leaf over; `tapped`, at a reading pace (a riffle keeps the brisk one).
    public func turnForward(tapped: Bool = true) {
        guard mode == .open else { return }
        // A tap past the last leaf closes the book (as turning the back cover over would).
        guard spread < leafCount else { if tapped { close() }; return }
        turned[spread] = true
        spread += 1
        pushTurned(tapped ? spread - 1 : nil)
    }

    public func turnBack(tapped: Bool = true) {
        guard mode == .open else { return }
        // A tap back past the first leaf closes the front cover.
        guard spread > 0 else { if tapped { close() }; return }
        spread -= 1
        turned[spread] = false
        pushTurned(tapped ? spread : nil)
    }

    private func pushTurned(_ tapped: Int? = nil) {
        renderer.update { $0.turned = self.turned; $0.tapped = tapped }
        loadPages()
        wake()
    }

    /// Navigate to a spread (0...leaf count), optionally riffling through the intervening leaves.
    public func go(to spread: Int, animated: Bool = true) {
        guard mode == .open else { return }
        let leaf = min(leafCount, max(0, spread))
        if animated { riffle(to: leaf) } else { jump(to: leaf) }
    }

    /// A riffle takes this long however far it goes, and shows at most this many leaves turning.
    static let riffleTime = 0.8
    static let riffleShown = 9

    /// To `leaf` (the contents page's rows, its ≡) in a set time (`riffleTime`): every leaf turning, spaced to fit; a
    /// long way goes over at once but for its last `riffleShown` leaves (the pages it lands on photographed first), which
    /// then riffle.
    private func riffle(to leaf: Int) {
        riffle?.cancel()
        let distance = abs(leaf - spread)
        guard distance > 0 else { return }
        let shown = min(distance, Self.riffleShown)
        if distance > shown { jump(to: leaf + (leaf > spread ? -shown : shown)) }
        let gap = Self.riffleTime / Double(shown)
        riffle = Task { [weak self] in
            while let self, !Task.isCancelled, self.spread != leaf, self.mode == .open {
                if self.spread < leaf { self.turnForward(tapped: false) } else { self.turnBack(tapped: false) }
                try? await Task.sleep(for: .seconds(gap))
            }
        }
    }

    /// Straight to `leaf`'s spread, no leaf in the air: its two pages photographed first, so it lands on print.
    private func jump(to leaf: Int) {
        for i in 0..<leafCount { turned[i] = i < leaf }
        spread = leaf
        if leaf > 0 { reprint(BookTextureKey(leaf: leaf - 1, verso: true)) }
        if leaf < leafCount { reprint(BookTextureKey(leaf: leaf, verso: false)) }
        renderer.update { $0.turned = self.turned; $0.snap = true }
        loadPages()
    }

    // MARK: - Gestures

    func tap(at point: CGPoint) {
        switch mode {
        case .compact, .closing:
            if compactRect.contains(point) { open() }
        case .opening:
            // Not yet open: a tap off where it is going takes it back (cancellable).
            if !openBook.contains(point) { close() }
        case .open:
            let page = rightPage
            guard openBook.contains(point) else { close(); return }
            if page.contains(point) {
                let u = (point.x - page.minX) / page.width, v = (point.y - page.minY) / page.height
                let location = CGPoint(x: u, y: v)
                if document.leaves.indices.contains(spread), document.leaves[spread].recto.onTap?(location) == true { return }
                if !sideways && u < 0.22 {
                    turnBack(tapped: true)
                } else {
                    turnForward(tapped: true)
                }
            } else {
                turnBack(tapped: true)
            }
        }
    }

    /// Where the open book lies (both pages sideways), with a margin round it.
    private var openBook: CGRect {
        let page = rightPage
        return CGRect(x: page.minX - (sideways ? page.width : 0), y: page.minY,
                      width: page.width * (sideways ? 2 : 1), height: page.height).insetBy(dx: -16, dy: -16)
    }

    /// What a drag on the open book is doing: turning a leaf, pulling the book down to put it away, or turning past an
    /// end (the last leaf on, or back past the first: the book closes).
    private enum Gesture { case none, leaf, lower, pastEnd(forward: Bool) }
    @ObservationIgnored private var gesture = Gesture.none

    /// How far a drag down puts the book away, or how fast.
    static let lowerDistance: CGFloat = 110
    static let lowerSpeed: CGFloat = 650

    func pan(_ state: UIGestureRecognizer.State, translation t: CGPoint, velocity v: CGPoint) {
        guard mode == .open else { return }
        let translation = t.x, velocity = v.x
        let span = rightPage.width * (sideways ? 1.5 : 1.15)
        if state == .began {
            riffle?.cancel()
            gesture = .none
            if v.y > 0, abs(v.y) > abs(v.x) * 1.2 {
                // Down, more than sideways: the book follows the finger, to be put away.
                gesture = .lower
            } else {
                let forward = velocity < 0 || (velocity == 0 && translation < 0)
                if forward, spread < leafCount { drag = (spread, true); gesture = .leaf }
                else if !forward, spread > 0 { drag = (spread - 1, false); gesture = .leaf }
                else { drag = nil; gesture = .pastEnd(forward: forward) }
            }
        }
        switch gesture {
        case .lower:
            if state == .began || state == .changed {
                renderer.update { $0.lowered = Float(max(0, t.y)) }
                wake()
            } else {
                let away = state == .ended && (t.y > Self.lowerDistance || v.y > Self.lowerSpeed)
                renderer.update { $0.lowered = nil }
                if away { close() } else { wake() }
                gesture = .none
            }
            return
        case .pastEnd(let forward):
            // Past the last leaf, or back past the first: a turn that far closes the book.
            if state == .ended {
                let q = (forward ? -translation : translation) / span
                if q > 0.3 || (forward ? velocity < -260 : velocity > 260) { close() }
            }
            if state != .began && state != .changed { gesture = .none }
            return
        case .none, .leaf:
            break
        }
        switch state {
        case .began, .changed:
            guard let drag else { return }
            let q = Float(max(0, min(1, (drag.forward ? -translation : translation) / span)))
            let angle = drag.forward ? q * .pi : (1 - q) * .pi
            renderer.update { $0.drag = BookDrag(leaf: drag.leaf, angle: angle, forward: drag.forward) }
            wake()
        case .ended, .cancelled, .failed:
            guard let drag else { return }
            self.drag = nil
            let q = (drag.forward ? -translation : translation) / span
            let flung = drag.forward ? velocity < -260 : velocity > 260
            let pulledBack = drag.forward ? velocity > 260 : velocity < -260
            let completes = state == .ended && (flung || (q > 0.45 && !pulledBack))
            if completes {
                if drag.forward { turned[drag.leaf] = true; spread = drag.leaf + 1 }
                else { turned[drag.leaf] = false; spread = drag.leaf }
            }
            let omega = Float(max(-14, min(14, -velocity / span * .pi)))
            renderer.update {
                $0.drag = nil
                $0.turned = self.turned
                $0.release = (drag.leaf, omega)
            }
            gesture = .none
            loadPages()
            wake()
        default:
            break
        }
    }

    /// Photograph one page again (its content changed) and put it on its leaf.
    private func reprint(_ key: BookTextureKey) {
        photograph(key, width: restingFaces.contains(key) ? sharpWidth : NotebookPage.pixelWidth)
    }

    /// Photograph a page `width` pixels wide and put it on its leaf.
    private func photograph(_ key: BookTextureKey, width: CGFloat) {
        let image = switch key {
        case .frontPastedown: document.frontInsideCover.image(width: width)
        case .backPastedown: document.backInsideCover.image(width: width)
        default: (key.verso ? document.leaves[key.leaf].verso : document.leaves[key.leaf].recto).image(width: width)
        }
        loaded[key] = width
        let texture = image.flatMap { self.texture($0) }
        renderer.update { $0.textures[key] = .some(texture ?? image) }
        wake(moving: false)
    }

    /// The pages the open book shows at rest: the right-hand page, and sideways the left-hand one (a board's
    /// pastedown at either end).
    private var restingFaces: Set<BookTextureKey> {
        var faces: Set<BookTextureKey> = [spread < leafCount ? BookTextureKey(leaf: spread, verso: false) : .backPastedown]
        if sideways { faces.insert(spread > 0 ? BookTextureKey(leaf: spread - 1, verso: true) : .frontPastedown) }
        return faces
    }

    // MARK: - Pages

    /// A page as a texture with all its mipmaps (made on the view's GPU, once it has one).
    private func texture(_ image: CGImage) -> (any MTLTexture)? {
        if textureLoader == nil, let device = view?.device ?? MTLCreateSystemDefaultDevice() {
            textureLoader = MTKTextureLoader(device: device)
        }
        return try? textureLoader?.newTexture(cgImage: image, options: [
            .generateMipmaps: true, .SRGB: true,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ])
    }

    /// Waits for the book to be still (cancelled with the task that waits).
    private func untilStill() async {
        while !still, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Closed again: the page pictures go (the next opening photographs them afresh).
    private func releasePages() {
        pageLoad?.cancel()
        let held = loaded.keys
        loaded.removeAll()
        renderer.update { input in for key in held { input.textures[key] = .some(nil) } }
    }

    /// Photograph the pages near the open spread (both faces of two leaves either side), the nearest first, and let
    /// the others go back to plain paper. The second leaf either side (all a turn adds; no page shows before the next
    /// turn) waits until the book is still. Once the turning has rested a moment, the pages at rest are photographed
    /// again at `sharpWidth` (not on every leaf a riffle passes).
    private func loadPages() {
        guard active, view != nil else { return }
        var wanted: [BookTextureKey] = [.frontPastedown, .backPastedown]
        var soon = 0
        for distance in 0...2 {
            for leaf in Set([spread + distance, spread - 1 - distance]) where (0..<leafCount).contains(leaf) {
                wanted += [BookTextureKey(leaf: leaf, verso: leaf < spread), BookTextureKey(leaf: leaf, verso: leaf >= spread)]
            }
            if distance == 1 { soon = wanted.count }
        }
        let dropped = Set(loaded.keys).subtracting(wanted)
        if !dropped.isEmpty {
            renderer.update { input in for key in dropped { input.textures[key] = .some(nil) } }
            for key in dropped { loaded[key] = nil }
        }
        let sharp = restingFaces.filter { (loaded[$0] ?? 0) < sharpWidth }
        pageLoad?.cancel()
        pageLoad = Task { [weak self] in
            for (index, key) in wanted.enumerated() {
                guard let self, !Task.isCancelled else { return }
                if self.loaded[key] != nil { continue }
                if index >= soon { await self.untilStill() }
                guard !Task.isCancelled else { return }
                self.photograph(key, width: NotebookPage.pixelWidth)
                await Task.yield()
            }
            guard !sharp.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(350))
            await self?.untilStill()
            for key in sharp {
                guard let self, !Task.isCancelled, self.mode != .compact else { return }
                self.photograph(key, width: self.sharpWidth)
                await Task.yield()
            }
        }
    }
}
#endif
