#if os(iOS)
import SwiftUI
import UIKit
import simd

/// A physical leaf has a front (recto) and a back (verso).
@MainActor
public struct NotebookLeaf {
    public let recto: NotebookPage
    public let verso: NotebookPage

    public init(recto: NotebookPage, verso: NotebookPage? = nil) {
        self.recto = recto
        self.verso = verso ?? .blank
    }
}

/// Immutable topology; page builders may read changing host data. Call `invalidatePages()` to refresh it.
@MainActor
public struct NotebookDocument {
    public let leaves: [NotebookLeaf]
    public let frontInsideCover: NotebookPage
    public let backInsideCover: NotebookPage

    public init(leaves: [NotebookLeaf], frontInsideCover: NotebookPage? = nil,
                backInsideCover: NotebookPage? = nil) {
        precondition(!leaves.isEmpty, "Notebook needs at least one leaf.")
        self.leaves = leaves
        self.frontInsideCover = frontInsideCover ?? .blank
        self.backInsideCover = backInsideCover ?? .blank
    }
}

/// A SwiftUI view photographed onto paper. Interactive controls inside it are not live controls.
@MainActor
public struct NotebookPage {
    public static let size = CGSize(width: 390, height: 570)
    static let pixelWidth: CGFloat = 1024
    let content: () -> AnyView
    let onTap: ((CGPoint) -> Bool)?
    public let accessibilityLabel: String

    /// `onTap` receives normalized coordinates (0...1, origin top-left). Return true to consume the tap.
    public init<Content: View>(accessibilityLabel: String, onTap: ((CGPoint) -> Bool)? = nil,
                               @ViewBuilder content: @escaping () -> Content) {
        self.accessibilityLabel = accessibilityLabel
        self.onTap = onTap
        self.content = { AnyView(content()) }
    }

    public static var blank: NotebookPage {
        NotebookPage(accessibilityLabel: "Blank page") { Color.clear }
    }

    /// A convenient default layout; use the view-builder initializer for your own design.
    public static func text(title: String, body: String) -> NotebookPage {
        NotebookPage(accessibilityLabel: "\(title). \(body)") {
            VStack(alignment: .leading, spacing: 24) {
                Text(title).font(.system(size: 32, weight: .semibold, design: .serif))
                Text(body).font(.system(size: 20, design: .serif)).lineSpacing(7)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(red: 0.17, green: 0.16, blue: 0.14))
            .padding(36)
        }
    }

    func image(width: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content:
            content()
                .frame(width: Self.size.width, height: Self.size.height)
                .background(Color(BookMaterials.paper))
                .environment(\.colorScheme, .light)
                .environment(\.dynamicTypeSize, .medium)
        )
        renderer.scale = width / Self.size.width
        renderer.isOpaque = true
        return renderer.cgImage
    }
}

/// Cover appearance belongs to this book instance, never global application state.
public struct NotebookCover {
    public var title: String
    public var spineTitle: String
    public var leatherColor: UIColor
    public var foilColor: UIColor

    public init(title: String = "NOTEBOOK", spineTitle: String = "NOTEBOOK",
                leatherColor: UIColor = UIColor(red: 0.30, green: 0.19, blue: 0.13, alpha: 1),
                foilColor: UIColor = UIColor(red: 0.86, green: 0.70, blue: 0.40, alpha: 1)) {
        self.title = title
        self.spineTitle = spineTitle
        self.leatherColor = leatherColor
        self.foilColor = foilColor
    }
}

public struct NotebookLighting: Equatable, Sendable {
    public var direction: SIMD3<Float>
    public var shadow: Float
    public var strength: Float
    public var tint: SIMD3<Float>
    public var fill: Float

    public init(direction: SIMD3<Float> = SIMD3(0.32, -0.42, 1), shadow: Float = 1,
                strength: Float = 1, tint: SIMD3<Float> = SIMD3(repeating: 1), fill: Float = 1) {
        self.direction = simd_length(direction) > 0 ? simd_normalize(direction) : SIMD3(0, 0, 1)
        self.shadow = min(1, max(0, shadow))
        self.strength = max(0, strength)
        self.tint = tint
        self.fill = max(0, fill)
    }
}

/// Put this last in a full-screen ZStack. Closed, only the book intercepts touches.
/// Keep its controller in @State and attach a controller to only one visible NotebookView at a time.
@MainActor
public struct NotebookView: View {
    private let controller: NotebookController
    private let placement: NotebookPlacement?
    private let quarterTurns: Int
    @Environment(\.scenePhase) private var scenePhase

    public init(controller: NotebookController, placement: NotebookPlacement? = nil, quarterTurns: Int = 0) {
        precondition((-1...1).contains(quarterTurns), "Use -1, 0 or 1 quarter turns.")
        self.controller = controller
        self.placement = placement
        self.quarterTurns = quarterTurns
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(BookMaterials.scrim)
                    .opacity(controller.dims ? BookMotion.scrim : 0)
                    .animation(.easeInOut(duration: BookMotion.scrimFade), value: controller.dims)
                    .allowsHitTesting(false)
                NotebookScene(controller: controller, insets: geometry.safeAreaInsets, placement: placement, turns: quarterTurns)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(controller.accessibilitySummary)
                    .accessibilityAction { if controller.isOpen { controller.turnForward() } else { controller.open() } }
                    .accessibilityAction(named: "Open notebook") { controller.open() }
                    .accessibilityAction(named: "Next page") { controller.turnForward() }
                    .accessibilityAction(named: "Previous page") { controller.turnBack() }
                    .accessibilityAction(named: "Close notebook") { controller.close() }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(!controller.stowed)
        .onChange(of: scenePhase) { _, phase in controller.setActive(phase == .active) }
    }
}

private struct NotebookScene: UIViewRepresentable {
    let controller: NotebookController
    let insets: EdgeInsets
    let placement: NotebookPlacement?
    let turns: Int

    func makeUIView(context: Context) -> BookSceneView {
        let view = BookSceneView(frame: .zero, options: nil)
        controller.attach(view)
        return view
    }

    func updateUIView(_ view: BookSceneView, context: Context) {
        let safe: UIEdgeInsets
        switch turns {
        case 1: safe = UIEdgeInsets(top: insets.trailing, left: insets.top, bottom: insets.leading, right: insets.bottom)
        case -1: safe = UIEdgeInsets(top: insets.leading, left: insets.bottom, bottom: insets.trailing, right: insets.top)
        default: safe = UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
        }
        if view.safeInsets != safe || view.place != placement || view.turns != turns {
            view.place = placement
            view.turns = turns
            view.safeInsets = safe
            view.setNeedsLayout()
        }
    }

    static func dismantleUIView(_ view: BookSceneView, coordinator: ()) {
        view.controller?.detach(view)
    }
}
#endif
