# Integration

## Leaves and spreads

A leaf has a `recto` (front) and `verso` (back). A document needs at least one leaf. Spread `0` shows the first recto on the right and the front inside cover on the left. Spread `n` shows leaf `n - 1`'s verso on the left and leaf `n`'s recto on the right. Spread `leaves.count` shows the back inside cover on the right. Portrait shows only the right face: put essential reading content on rectos.

Topology is immutable for a controller's lifetime. Create a new controller when the number/order of leaves changes. Do not replace the controller in an already-mounted `NotebookView`; give the view a new `.id(...)` with the new document identity so its SceneKit view is recreated. Each controller belongs to at most one visible `NotebookView`.

## Custom pages

```swift
let page = NotebookPage(accessibilityLabel: "Day one. A sketch of a mountain.") {
    VStack(spacing: 24) {
        Text("Day one").font(.system(size: 32, design: .serif))
        Image(systemName: "mountain.2").font(.system(size: 96))
        Text("A quiet start.")
    }
    .padding(36)
}
```

Page builders run on the main actor. Pages use a fixed **390 × 570 point** canvas, an opaque warm paper background, light color scheme and medium Dynamic Type. They are photographed with `ImageRenderer`, normally 1024 pixels wide, up to 2048 for resting pages on larger displays. Fit content to the canvas; pages do not scroll. Resolve async images/data in your app before rendering and use assets from your app's own bundle.

Views become textures: Buttons, TextFields, scrolling, video and accessibility elements inside the page are not live UI. Use `accessibilityLabel` to provide readable content and native host controls for editing, larger text, search or complex interactions. Notebook exposes VoiceOver actions for opening, turning and closing. It does not yet implement a Reduce Motion presentation; provide an ordinary SwiftUI reading alternative where required.

A recto can consume a tap using normalized coordinates:

```swift
let page = NotebookPage(
    accessibilityLabel: "Photo of the garden. Open photo for detail.",
    onTap: { point in
        guard point.x > 0.25 && point.x < 0.75 && point.y < 0.5 else { return false }
        // Present host-owned detail UI here.
        return true
    }
) {
    Image("GardenPhoto").resizable().scaledToFit().padding(30)
}
```

Returning false allows normal page turning. Custom hit regions currently apply to the right-hand page only; left-page taps turn backward.

## Controls and updates

All controller APIs are main-actor isolated.

| API | Behavior |
| --- | --- |
| `open()` / `close()` | Animate presentation; opening can be cancelled |
| `turnForward()` / `turnBack()` | Turn one leaf when open; turning past an end closes |
| `go(to: 0, animated: true)` | Riffle to a spread; index clamped to document bounds; requires open state |
| `spread` | Read-only index of the requested spread, updated when a turn is committed |
| `mode` | `.compact`, `.opening`, `.open`, `.closing` |
| `isOpen` | True while opening or open; suitable for showing host toolbar controls |
| `stowed` | Move the closed book offscreen and disable hit testing; close first before stowing an open book |
| `invalidatePages()` | Re-render nearby pages from the current captured data |
| `soundEnabled` | Opt-in procedural page audio; false by default |
| `setLighting(_:)` | Match the host's lighting direction, color, fill and shadow strength |
| `setActive(_:)` | Pause/resume rendering and audio; NotebookView follows scenePhase automatically |

Capture a reference model in page builders for live data, then call `invalidatePages()` after edits. The package saves no data. Host applications own persistence, sync, text entry, handwriting and photo detail presentation. Navigation requests during opening are ignored; wait for `mode == .open` before `go(to:)`.

## Placement and rotation

The default adapts to the container's actual orientation. Use normal app-supported orientations for ordinary apps; no motion sensor or global orientation locking is needed.

For an app whose interface stays portrait while its content rotates, pass `quarterTurns: -1`, `0` or `1` to `NotebookView`. The SceneKit camera rolls without resizing its drawable. For toolbar avoidance or a different closed-book edge, pass a `NotebookPlacement`:

```swift
NotebookView(controller: book, placement: NotebookPlacement(
    icons: [CGRect(x: 16, y: 60, width: 44, height: 44)],
    column: true,
    compactEdge: .right,
    compactAlong: 600,
    roomy: true
))
```

Coordinates are local points in the orientation facing the reader. Compute positions from the container size; the numeric example is illustrative. `icons` reserves space around host controls; `column` describes a side toolbar; `creaseCentred` centers a landscape spread's spine; `roomy` adds padding for large displays. Safe-area insets are supplied by the wrapper.

## Audio ownership

The package synthesizes page rustle and landing sounds with AVAudioEngine. It does not configure or activate AVAudioSession, and it does not load sound files. Set your app's desired audio category/mixing policy before enabling sounds. The demo uses the system's default session policy. Audio interruptions, route changes and subjective balance should be checked in each host app. Opening/closing the cover itself remains silent.

## Versioning

Start with `.upToNextMinor(from: "0.1.1")`. This is an initial extracted API, so minor releases before 1.0 may change source compatibility; patch releases are intended for compatible fixes. Import only `Notebook` and rely on documented public types. `Book*` types are implementation details.
