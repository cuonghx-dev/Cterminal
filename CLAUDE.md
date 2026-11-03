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
```

## Pitfalls

- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- Closing a terminal must call `TerminalSurface.close()` (`TabManager.closeTab` / `closeSurface(tabId:surfaceId:)` do). Removing a surface from the split tree alone leaves its shell running: view handlers retain the surface, so `deinit` (and `ghostty_surface_free`) may never run. `Tab.closeSurface` / `detachSurface` only re-layout, because drag-and-drop moves reuse the live surface.
