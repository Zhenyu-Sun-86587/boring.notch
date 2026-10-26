# Hermes Island fork

This branch targets ARM64 macOS 27. Music, battery, OSD and Shelf remain available.
Apple EventKit is replaced by the Vikunja adapter. Upstream Sparkle checks are disabled for this fork.

## Configuration

Open Settings → **Hermes & Todo**. Service addresses, model and credentials intentionally start empty;
the app makes no service request until an address is configured. No server configuration is performed by this fork.

- **Hermes:** enter the complete `http(s)://…/v1/chat/completions` endpoint, model identifier and optional API Key.
  The gateway must return OpenAI-compatible SSE (`delta.content`, `[DONE]`). Enter submits; use Shift+Enter for a newline.
- **Todo:** enter the Vikunja instance root (without `/dav/` or `/api/v1`) and an API token.
  Optional Cloudflare Access Client ID / Secret are sent only to that host; redirects are rejected.
  The client prefers v2 and falls back to v1 only for 404/405 on the v2 discovery route.
  Project 3 is always excluded; additional comma-separated project IDs can be excluded.
  v2 writes require an ETag and use `If-Match`; v1 preserves the latest complete payload but cannot guarantee atomic conflict detection.
- **HermesSurface:** select `/Users/sunzhenyu/Desktop/sync/HermesSurface` once to authorize the directory.
  `@today` / `@inbox` read the latest `Today.md` / `Inbox.md` on send; missing or unreadable files block that send.
  **存入待办** appends one checkbox to the existing `Today.md`, with subsequent answer lines indented.
  It does not create a remote task or import Markdown task projections into the timeline.

Credentials are stored in Keychain, other preferences and the security-scoped directory bookmark in app defaults.
No credentials, live service addresses or note contents are committed to the repository.

## Interaction and resource bounds

- Hover opens the existing notch; select Hermes to type. Only the panel under the pointer can take keyboard focus.
  Leaving Hermes collapses after 350 ms; lock screen closes Hermes and cancels generation.
- Compact 640×420 / wide 920×520, clamped to the current screen. Code fences and Markdown tables widen automatically.
- Native Textual rendering supports Markdown and `$…$` / `$$…$$` math, with a separate copy action per code block.
  No WebKit process is introduced. Raw HTML is not executed.
- Eight conversation turns, 256 KiB history, 128 KiB output, 64 KiB prompt / text attachment, six attachments.
  ImageIO downsamples images to 1600 px before JPEG encoding; encoded image parts are not retained in conversation history.
- Network generation stops when the last drawer disappears; context expires after 15 minutes closed.
  Todo refreshes on appearance and every 60 seconds while visible; file watching uses directory events while Hermes is visible.

## Build and verification

The **Hermes Ad-hoc Build** Action runs on branch pushes or manual dispatch. It selects Xcode 27.1,
builds ARM64 without certificate secrets, signs nested code inside out, verifies signatures and architectures,
then uploads `Boring Notch.app.zip`, `SHA256SUMS`, commit SHA and signing diagnostics.
The shared scheme is tracked explicitly. No upstream release, appcast or Homebrew publication is invoked.

Local Command Line Tools can run:

```sh
swift run --package-path Packages/IslandCore IslandCoreChecks
python3 .github/scripts/test_island_stream.py
python3 -m unittest discover -s .github/scripts/tests -q
```

Core checks use temporary files and fixture HTTP responses. The streaming integration binds only to localhost.
They do not read or change real notes or tasks. Full SwiftUI app compilation requires Xcode and is validated in Actions.

Manual acceptance after downloading the artifact: hover focus and Chinese composition; return to the prior app on close;
compact/wide transitions on each display; image/text drops; tables, code and inline/display math; configured remote read/update;
append preservation with the user's sync tool; music, battery, OSD and Shelf regression.
Only mark these passed after observing the built application.

Measure physical footprint and CPU for both original and fork under the same idle, music and chat scenarios, including repeated opens/closes.
The 50/80 MB figures are optimization targets. The earlier installed-app sample (~107 MB) is a reference, not a measurement of this build.
