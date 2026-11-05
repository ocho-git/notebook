import Notebook
import SwiftUI

@main
struct NotebookDemoApp: App {
    var body: some Scene { WindowGroup { DemoView() } }
}

struct DemoView: View {
    @State private var book = NotebookController(
        document: NotebookDocument(leaves: [
            NotebookLeaf(recto: .text(title: "A little notebook", body: "Your app's content, inside a real turning book.\n\nSwipe or tap to turn a leaf. Rotate to see both sides."),
                         verso: .text(title: "Made for your app", body: "Recipes, lessons, a journal, a field guide. The book supplies the movement; you supply the pages.")),
            NotebookLeaf(recto: NotebookPage(accessibilityLabel: "A custom page with a green leaf illustration and a caption.") {
                VStack(spacing: 30) {
                    Image(systemName: "leaf").font(.system(size: 120, weight: .ultraLight)).foregroundStyle(.green)
                    Text("Anything you can draw in SwiftUI.").font(.system(size: 26, design: .serif)).multilineTextAlignment(.center)
                }.padding(40)
            }, verso: .text(title: "On the other side", body: "Each leaf has two faces. In portrait you read the right face; landscape reveals the whole spread.")),
            NotebookLeaf(recto: .text(title: "Keep exploring", body: "Drag down, pinch inward, or tap outside to close.\n\nThe cover waits at the screen's edge until you need it again."))
        ]),
        cover: NotebookCover(title: "LITTLE\nNOTEBOOK", spineTitle: "NOTEBOOK")
    )

    var body: some View {
        ZStack {
            Color(red: 0.87, green: 0.88, blue: 0.84).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Notebook").font(.largeTitle.weight(.light))
                Text("Tap the book at the edge to begin.").foregroundStyle(.secondary)
                Button("Open notebook") { book.open() }.buttonStyle(.bordered)
                Toggle("Page sounds", isOn: $book.soundEnabled).frame(width: 220)
                Text("Rotate for a two-page spread").font(.footnote).foregroundStyle(.secondary)
            }
            NotebookView(controller: book)
            if book.isOpen {
                VStack {
                    HStack {
                        Button("Close", systemImage: "xmark") { book.close() }
                        Spacer()
                        Button("First page", systemImage: "list.bullet") { book.go(to: 0) }
                    }.padding()
                    Spacer()
                }
            }
        }
    }
}
