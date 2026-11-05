# Visual examples

The README images are generated from the current package sources using `SCNRenderer` offscreen on the Mac. They are not AI-generated artwork or simulated book mockups. Custom example pages are real `NotebookPage` SwiftUI views photographed by the package's `ImageRenderer` path.

| Asset | Shows |
| --- | --- |
| `Images/notebook-motion.gif` | Cover opening, one page turning, and closing; 150 frames at 15 fps |
| `Images/cover.png` | Brown leather, gold foil and custom cover/spine lettering |
| `Images/spread.png` | Two-page spread with custom observation notes and a leaf illustration |
| `Images/page-fold.png` | A frozen page turn showing the actual curl geometry |
| `Images/recipes-cover.png` | Green leather with alternative lettering |
| `Images/recipes.png` | A recipe book using the same engine with different SwiftUI content |

## Regenerate

On a Mac with Xcode installed:

```sh
./scripts/render-examples.sh
```

The script builds a temporary command-line executable for Mac Catalyst and runs it without creating an application window, launching a simulator, or accessing a physical device. It needs GPU access for SceneKit. The package sources are compiled directly; the temporary audio source adds an explicit CoreAudio import required by this Catalyst command-line build. No audio is played. Build products are removed when the script exits; the six images are written to `Documentation/Images/`.

The fixtures in `scripts/render-examples.swift` provide custom pages, lighting and a presentation layout. Closed covers are staged fully in frame rather than partially beyond the screen's edge. Stills use frozen poses; the animation integrates the renderer's actual spring motion at 60 Hz and exports at 15 fps. These visuals demonstrate the rendering engine and content customization. They do not verify UIKit gestures, safe-area layout, VoiceOver, audio or device performance, and do not establish supported Mac Catalyst app integration.

The initial visuals were generated with Xcode 27.1 on 5 November 2026. Exact rasterization may vary with SDK, system fonts or GPU.
