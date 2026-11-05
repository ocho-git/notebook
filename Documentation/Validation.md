# Validation

Initial extraction checked on 5 November 2026 using Xcode 27.1 (27A9275).

- `swift test`: 9 tests passed on macOS. These exercise fold endpoints, finite normalized geometry through 101 turn positions across several stack heights, collision-floor constraints, paper length, stack separation, spring convergence/reversal, the atomic sound feed, silent cover motion, and bounded page audio.
- Unsigned **generic iOS** demo build: passed.
- Unsigned **generic iOS Simulator** demo build: passed. This compiles for the Simulator SDK; it does not run a simulator.
- The checked-in Xcode project imports and uses the package as a separate local dependency, exercising its public API across the module boundary.
- Offscreen documentation renders: the actual SceneKit renderer and SwiftUI page snapshots were compiled for Mac Catalyst and rendered without an application window. Five stills and a 150-frame opening/turning/closing GIF were generated; stills and representative animation frames were visually inspected. See [visual examples](VisualExamples.md).
- No simulator or physical device was booted, opened or used. On-device appearance, touch behavior, VoiceOver behavior, interruption handling and subjective audio have not been observed for the extracted demo. The original app's prior testing is not a substitute for testing this package in a new host.

Run `./scripts/check.sh` to repeat the automated checks. It does not require distribution signing. Xcode may print a harmless App Intents metadata warning because the demo has no App Intents dependency.

Before shipping a host integration, run the demo and that host on the intended devices. Check opening and cancelling, swipes and interrupted drags, all spreads in portrait/landscape, rapid navigation, toolbar hit areas, background/foreground transitions, removal/reattachment, multiple independent books, VoiceOver actions, and audio with the host's actual session policy. Provide a native reading alternative for Dynamic Type and Reduce Motion requirements.
