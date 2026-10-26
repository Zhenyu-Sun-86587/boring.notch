# Island geometry diagnostics

This build includes opt-in diagnostics for the reported gap above the notch when a
tall Hermes/Clipboard page changes to Home/Shelf or closes. The recorder does not
change layout, animation, window positioning, or keyboard handoff behavior.

The user reproduced the gap on `dc23f2c` with tracing enabled. Across both high-to-Shelf
transitions the window, host and bridge anchor stayed at the screen top; the
WindowServer transform did not change. The user confirmed that desktop pixels,
rather than only lowered header content, were visible. That evidence narrows the
failure to rendering below the measured shell geometry; it does not establish a
window-origin or frame-size fault.

The next change places the content, clip and black background in one
`geometryGroup()`. Apple's [geometryGroup documentation](https://developer.apple.com/documentation/swiftui/view/geometrygroup())
explains how a geometry boundary resolves parent position/size changes before
passing them to independently inserted drawing leaves. This is a focused rendering
change, with no offset or timing compensation. It still requires validation against
the user's actual reproducer; passing fixtures alone does not prove the reported
gap is fixed.

Start a fresh app process with `--island-geometry-trace`, for example:

```sh
open -a /path/to/boringNotch.app --args --island-geometry-trace
```

The environment variable `BORING_GEOMETRY_TRACE=1` or the app preference
`island.geometryTraceEnabled=true` also enables tracing at process startup. The
command-line option requires no persistent preference change. Tracing is off by default.

The file is `boring-notch-geometry-<PID>.jsonl` in the app process's temporary directory
(`FileManager.default.temporaryDirectory`; normally the directory reported by
`getconf DARWIN_USER_TEMP_DIR`). Each process writes at most 2 MiB. A target/state
change, actual frame write, or keyboard action starts a sampling interval that stops
after 0.8 seconds; ordinary unchanged SwiftUI updates do not keep writing. New
transitions can start another interval until the file cap is reached.

Each JSON line uses the same monotonic clock and records geometry or fixed state only:

- Surface target, measured closed/compact sizes, tab, open state, gesture progress.
- Bridge request/generation and application of the requested window frame.
- Window, content view, hosting view and existing bridge anchor geometry, including
  available layer presentation geometry.
- Own-window WindowServer transform, or an unavailable/error status when the optional
  private read API cannot be resolved.
- Own-window keyboard admission/release and handoff ordering events.

No screenshots, text contents, titles, URLs, clipboard values, input events, or
session/owner identifiers are collected. The optional WindowServer reader is resolved
only after tracing has been enabled, and reads only the notch window being logged.

Independent fixture checks did not reproduce the reported gap, including a short
visible run with the production window class, bridge, keyboard handoff and private
space registration. The live application trace above supplies evidence those
fixtures could not. Pixel checks now include both shoulders immediately below the
top edge, since the header's central black notch can conceal a displaced background.
