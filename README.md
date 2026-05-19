# Denebula

Denebula is a macOS menu bar prototype for just-in-time text summarization using temporary clipboard copy/restore.

The first scaffold proves the core interaction: highlight text in another app, press `Command + Shift + Space`, and Denebula copies the selection, restores your prior clipboard, saves the text, and asks Codex to summarize it:

```text
capture -> [timestamp].md -> Codex -> [timestamp]-[tagline]-summary.md
```

## Build

```sh
swift build
```

## Run

```sh
swift run Denebula
```

For a more app-like run with a stable macOS app identity:

```sh
chmod +x scripts/package_app.sh
scripts/package_app.sh
open dist/Denebula.app
```

On first run, grant Accessibility permission in System Settings when prompted. Denebula uses that permission only to send `Command + C` to the frontmost app. It temporarily copies the selection, reads the copied text, and restores the previous clipboard contents.

Each successful capture is saved as a Markdown file in:

```text
~/Library/Application Support/Denebula/Captures/
```

Files are named to the nearest second, for example:

```text
2026-05-19_14-03-27.md
```

After saving the capture, Denebula runs the local Codex CLI using your Codex app login. Codex returns a short tagline and a full summary. Denebula saves the final summary beside the original file:

```text
2026-05-19_14-03-27-short-tagline-summary.md
```

If no text is copied, Denebula opens the past summaries list instead of starting a new summary.

When the captured text contains factual, verifiable claims, Codex also adds a short validity analysis to the saved summary. Non-factual text omits the validity section.

If System Settings says Denebula already has Accessibility permission but the app still reports that it does not, remove Denebula from the Accessibility list, quit Denebula, relaunch `dist/Denebula.app`, and add it again. Rebuilt unsigned prototype apps can leave stale macOS privacy entries behind.
