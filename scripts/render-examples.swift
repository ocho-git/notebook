import ImageIO
import Metal
import SceneKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Documentation fixtures compiled alongside the unmodified package sources.
// Direct SCNRenderer snapshots exercise the real scene, materials, curves and springs.
@main
struct RenderExamples {
    @MainActor static func page(title: String, eyebrow: String, text: String, symbol: String? = nil,
                                green: Bool = false) -> NotebookPage {
        NotebookPage(accessibilityLabel: title + ". " + text) {
            VStack(alignment: .leading, spacing: 20) {
                Text(eyebrow.uppercased()).font(.system(size: 10, weight: .medium)).tracking(3)
                    .foregroundStyle(Color(red: 0.44, green: 0.43, blue: 0.35))
                Text(title).font(.system(size: 38, weight: .regular, design: .serif))
                Rectangle().frame(height: 0.5).opacity(0.3)
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 110, weight: .ultraLight))
                        .foregroundStyle(green ? Color(red: 0.30, green: 0.40, blue: 0.27) : Color(red: 0.49, green: 0.37, blue: 0.24))
                        .frame(maxWidth: .infinity).frame(height: 145)
                }
                Text(text).font(.system(size: 18, design: .serif)).lineSpacing(6)
                Spacer(minLength: 0)
                Text("OCHO  /  NOTEBOOK").font(.system(size: 8, weight: .medium)).tracking(2).opacity(0.4)
            }
            .foregroundStyle(Color(red: 0.18, green: 0.20, blue: 0.16))
            .padding(34)
        }
    }

    @MainActor static func fixture(recipe: Bool = false) -> (NotebookRenderer, SCNRenderer, [Bool]) {
        let cover = recipe
            ? NotebookCover(title: "FAMILY\nRECIPES", spineTitle: "RECIPES", leatherColor: UIColor(red: 0.18, green: 0.29, blue: 0.23, alpha: 1))
            : NotebookCover(title: "LITTLE\nNOTEBOOK", spineTitle: "NOTEBOOK")
        let engine = NotebookRenderer(leafCount: 4, cover: cover)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = engine.scene
        renderer.pointOfView = engine.cameraNode
        renderer.autoenablesDefaultLighting = false
        engine.scene.background.contents = UIColor(red: 0.88, green: 0.89, blue: 0.86, alpha: 1)
        let pages: [NotebookPage] = recipe ? [
            page(title: "At the table", eyebrow: "A family collection", text: "Good things, passed around.\n\nRecipes to make slowly and share generously.", symbol: "fork.knife"),
            page(title: "Morning ritual", eyebrow: "Kitchen notes", text: "A warm pan. A little patience.\n\nLeave the batter to rest while the coffee brews."),
            page(title: "Sunday pancakes", eyebrow: "Recipe no. 01", text: "Flour, milk, eggs and a pinch of salt.\n\nMix gently, rest for ten minutes, then cook until golden.", symbol: "sun.max"),
            page(title: "Make it yours", eyebrow: "Serving notes", text: "Add berries, lemon or a spoonful of honey.\n\nThe best version is the one you make together.")
        ] : [
            page(title: "A little notebook", eyebrow: "Keep what matters", text: "A place for things worth noticing.\n\nYour pages. A familiar, tactile book.", symbol: "leaf", green: true),
            page(title: "Small observations", eyebrow: "Notes from a quiet day", text: "The light through the trees.\nThe shape of a fallen leaf.\nA thought worth returning to.\n\nSome things deserve a page of their own."),
            page(title: "Room to grow", eyebrow: "A page of your own", text: "Field guides, journals, recipes and lessons.\n\nBring your own SwiftUI content.", symbol: "leaf", green: true),
            page(title: "Turn a new leaf", eyebrow: "Made to be explored", text: "Tap, swipe, or follow the fold with your finger.\n\nEvery leaf has another side.")
        ]
        var textures: [BookTextureKey: Any?] = [:]
        for i in 0..<4 {
            textures[BookTextureKey(leaf: i, verso: false)] = pages[min(i * 2, 3)].image(width: 1200)
            textures[BookTextureKey(leaf: i, verso: true)] = pages[min(i * 2 + 1, 3)].image(width: 1200)
        }
        var layout = BookLayout()
        layout.viewHeight = 900
        layout.unitsPerPoint = 0.042
        layout.compactCenter = SIMD2(-8, -3)
        layout.compactScale = 0.9
        layout.compactRoll = -0.15
        layout.largeCenter = .zero
        layout.openSpine = .zero
        layout.largeScale = 1.15
        engine.update {
            $0.layout = layout
            $0.textures = textures
            $0.turned = [false, false, false, false]
            $0.light = NotebookLighting(direction: SIMD3(-0.4, -0.6, 1), shadow: 0.8)
        }
        return (engine, renderer, [false, false, false, false])
    }

    @MainActor static func frame(_ engine: NotebookRenderer, _ renderer: SCNRenderer,
                                 time: Double, size: CGSize) -> UIImage {
        engine.renderer(renderer, updateAtTime: time)
        SCNTransaction.flush()
        return renderer.snapshot(atTime: time, with: size, antialiasingMode: .multisampling4X)
    }

    @MainActor static func still(_ name: String, folder: URL, recipe: Bool = false,
                                 open: Bool, spread: Int = 0, fold: Float? = nil) throws {
        let (engine, renderer, _) = fixture(recipe: recipe)
        engine.update {
            $0.open = open
            if !open { $0.layout.compactCenter = .zero; $0.layout.compactScale = 1.15 }
            $0.turned = (0..<4).map { $0 < spread }
            $0.snap = true
            $0.freeze = fold.map { .turn($0) }
        }
        var image: UIImage!
        for i in 0..<4 { image = frame(engine, renderer, time: Double(i) / 60, size: CGSize(width: 1500, height: 900)) }
        try image.pngData()!.write(to: folder.appendingPathComponent(name + ".png"))
        print("Rendered \(name)")
    }

    @MainActor static func animation(folder: URL) throws {
        let (engine, renderer, _) = fixture()
        let url = folder.appendingPathComponent("notebook-motion.gif")
        let count = 150
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else { fatalError("GIF destination") }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        // 15 output frames/second; integrate at 60 Hz using the real renderer's springs.
        for index in 0..<count {
            if index == 12 { engine.update { $0.open = true; $0.presentationID = 1 } }
            if index == 55 { engine.update { $0.turned = [true, false, false, false]; $0.tapped = 0 } }
            if index == 96 { engine.update { $0.open = false } }
            var image: UIImage!
            for subframe in 0..<4 {
                let time = Double(index * 4 + subframe) / 60
                engine.renderer(renderer, updateAtTime: time)
            }
            SCNTransaction.flush()
            image = renderer.snapshot(atTime: Double(index) / 15, with: CGSize(width: 750, height: 450), antialiasingMode: .multisampling4X)
            // GIF stores centiseconds: 6/7/7 yields exactly 15 fps over each three frames.
            let delay = index % 3 == 0 ? 0.06 : 0.07
            CGImageDestinationAddImage(gif, image.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            if index % 30 == 0 { print("Animation frame \(index)/\(count)") }
        }
        guard CGImageDestinationFinalize(gif) else { fatalError("GIF encoding failed") }
        print("Rendered animation")
    }

    @MainActor static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try still("cover", folder: folder, open: false)
        try still("spread", folder: folder, open: true, spread: 1)
        try still("page-fold", folder: folder, open: true, fold: 82)
        try still("recipes", folder: folder, recipe: true, open: true, spread: 1)
        try still("recipes-cover", folder: folder, recipe: true, open: false)
        try animation(folder: folder)
    }
}
