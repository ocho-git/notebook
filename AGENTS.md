# Notebook integration and maintenance

Read README.md and Documentation/Integration.md before adding this package to an app. CLAUDE.md points here too.

- Public module/product: `Notebook`. iOS/iPadOS 18+, Swift 6.2 tools. Use the tagged GitHub URL from README.
- Keep one `NotebookController` in stable host state per displayed book. Never use a global singleton or create it inside `body`.
- Use `NotebookDocument`, `NotebookLeaf`, `NotebookPage` and `NotebookView`; do not copy the renderer into host apps.
- Page builders produce 390 × 570 point static snapshots. Keep editing, async loading, persistence, audio session policy and rich accessibility UI in the host.
- Put essential content on rectos because portrait shows only the right page.
- For model edits, invalidate page snapshots. For topology changes, create a controller and remount its view with a new identity.
- Do not silently reconfigure AVAudioSession, fetch network content, or assume Bundle.main resources inside the package.
- Keep controllers isolated; any new global mutable state is a regression.
- `./scripts/check.sh` runs Mac tests and unsigned generic iOS/device-SDK and Simulator-SDK builds. Do not launch a simulator or physical device unless the user explicitly asks for that in the current task.
- Test claims must distinguish compilation/math checks from observed rendering, gestures, accessibility and sound on a device.
- The repository is public; its proprietary license still applies. Do not change repository visibility or license without explicit authorization.
