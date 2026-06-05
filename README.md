# Miku Explains

Miku Explains is a whimsical macOS menu bar prototype for highlight-to-AI actions using temporary clipboard copy/restore.

The native Swift app owns the menu bar, global shortcut, clipboard capture, persistence, Codex CLI process, and window placement. The visible result panel is a bundled React UI hosted in a transparent `WKWebView`.

Highlight text in another app, press `Command + Shift + Space`, and Miku Explains copies the selection, restores your prior clipboard, saves the text, and asks Codex to infer what kind of help you likely want. The shortcut is configurable from the panel toolbar. When the panel is already open, pressing the shortcut closes it if nothing new is selected, or starts a fresh explanation if you highlighted different text.

```text
capture -> [timestamp].md -> Codex -> [timestamp]-[tagline]-result.json
```

## Build

```sh
swift build
```

## Run

```sh
swift run MikuExplains
```

For a more app-like run with a stable macOS app identity:

```sh
chmod +x scripts/package_app.sh
scripts/package_app.sh
open "dist/Miku Explains.app"
```

On first run, grant Accessibility permission in System Settings when prompted. Miku Explains uses that permission only to send `Command + C` to the frontmost app. It temporarily copies the selection, reads the copied text, and restores the previous clipboard contents.

Each successful capture is saved as a Markdown file in:

```text
~/Library/Application Support/MikuExplains/Captures/
```

After saving the capture, Miku Explains runs the local Codex CLI using your Codex app login. Codex returns a short tagline, an inferred intent, and dynamic result items rendered as React cards. If Codex decides web verification is useful, the app enters a green `Verifying` loading phase and runs a second `codex --search exec ...` pass.

The packaged app uses `Resources/miku_crop.png` as the rounded-square menu bar icon, `Resources/AppIcon.icns` as the bundle app icon generated from that same crop, `Resources/miku.png` as the React panel sticker, and `Resources/WebUI/` for the bundled panel UI.

If System Settings says Miku Explains already has Accessibility permission but the app still reports that it does not, remove Miku Explains from the Accessibility list, quit the app, relaunch `dist/Miku Explains.app`, and add it again. Rebuilt unsigned prototype apps can leave stale macOS privacy entries behind.
