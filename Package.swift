// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Notebook",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "Notebook", targets: ["Notebook"])],
    targets: [
        .target(name: "Notebook"),
        .testTarget(name: "NotebookTests", dependencies: ["Notebook"])
    ],
    swiftLanguageModes: [.v5]
)
