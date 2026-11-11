# Agent notes

Minimal Ghostty-based macOS terminal, branded `cter` (fork of cmux without auto-update, website, or release tooling).

## Setup

```bash
./scripts/setup.sh   # init ghostty submodule + build GhosttyKit.xcframework
```

## Build & run

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cter -configuration Debug -destination 'platform=macOS' build
./scripts/reload.sh               # kill + launch Debug app
./scripts/reload.sh --tag <name>  # isolated side-by-side app (own bundle ID, socket, derived data)
```

### Without Xcode (Command Line Tools only)

`xcodebuild` needs a full Xcode install. With only Command Line Tools, use:

```bash
./scripts/build-no-xcode.sh --open            # tag "nox": /tmp/cter-nox-swiftc/cter DEV nox.app
./scripts/build-no-xcode.sh --tag <name> --debug
```

It compiles `Sources/` with `swiftc` (`-O -wmo`, or `--debug`), links the prebuilt
`GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a`, and puts the binary into a copy of
`--base` (default `/Applications/CTerminal.app`). The copy gets a tagged bundle id, name and socket
like `reload.sh --tag`, with `CTER_SOCKET_MODE=full`, so tests reach it with `CTER_TAG=<name>`.
Build takes about 1.5 min.

Limits:
- Needs an existing GhosttyKit build and a base app; it does not run zig, `actool` or Metal.
- Only the binary, `Resources/mermaid` and `Resources/shell-integration` are refreshed. Info.plist,
  icon, terminfo and the `cter` CLI come from the base app, so a new resource or Info.plist key in
  the Xcode project must be added to the script too.
- `TerminalView.swift` (SwiftTerm) is not in the app target and is excluded.

To install a build as the main app, copy the built binary into a copy of `/Applications/CTerminal.app`
(keep its bundle id, no `LSEnvironment`), add `Resources/mermaid` and `Resources/shell-integration`,
ad-hoc sign it, and replace the old bundle (no backup needed). Replacing the bundle on disk is safe while the app runs; the new build
starts on next launch. Quitting the running app ends every tab's processes.

When rebuilding GhosttyKit.xcframework, always use Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Demit-macos-app=false -Doptimize=ReleaseFast
```

Requires the zig version in `ghostty/build.zig.zon` (`minimum_zig_version`, currently 0.16.0)
first in `PATH`; Ghostty's external translate-c step runs the `zig` found on `PATH`. After bumping
the submodule, copy `ghostty/include/ghostty.h` over the root `ghostty.h` (the bridging header imports
the root copy).

## Tests

Python socket tests in `tests/` drive a running app over `/tmp/cter.sock`:

```bash
python3 tests/test_ctrl_socket.py
CTER_TAG=nox python3 tests/test_close_tab_kills_processes.py   # tagged app from reload.sh / build-no-xcode.sh
```

The installed app's default socket mode rejects `list_tabs` / `new_tab` / `close_tab`; run tests
against a tagged build (socket mode `full`) via `CTER_TAG`.

## Pitfalls

- Never call `resignFirstResponder()` on a view directly; use `window.makeFirstResponder(_:)`. When the
  current responder is an `NSTextView`, the direct call raises `NSInternalInconsistencyException` and
  the uncaught exception quits the app (this closed every tab when a pane closed).
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- Closing a terminal must call `TerminalSurface.close()` (`TabManager.closeTab` / `closeSurface(tabId:surfaceId:)` do). Removing a surface from the split tree alone leaves its shell running: view handlers retain the surface, so `deinit` (and `ghostty_surface_free`) may never run. `Tab.closeSurface` / `detachSurface` only re-layout, because drag-and-drop moves reuse the live surface.
