# TUI SNAPSHOT TESTING: SWIFT-ONLY

## Why not PTY

The earlier plan specified Python + pyte + ptyprocess for E2E golden-file
comparison. Implementation revealed ~759 LOC of Python, 4 pip deps, and a
managed venv: maintenance cost that outweighed the marginal coverage over
what Swift can already do directly.

The TUI's rendering pipeline composes frames into a `BufferedScreen`
abstraction (`SwiftLMTUI.BufferedScreen`) **before** anything touches the
terminal. Snapshot-testing that buffer is equivalent to pyte's rendered
grid for our purposes: we do not need to test that the terminal
honors our ANSI escapes; we need to test that we emit the right cells.

## Approach

Two layers, both pure Swift, both run under `swift test`.

### Layer 1: panel snapshot tests

`Tests/SwiftLMTUITests/` gains one snapshot test per panel that:

1. Constructs a `BufferedScreen(rows: 30, cols: 120)`.
2. Constructs the panel (`MonitorTab`, `LibraryTab`, `ChatTab`) with
  deterministic state (a fixed snapshot dict / fake catalog / preset
   chat history).
3. Calls `tab.render(into: buffer, contentRows: 3...28)`.
4. Composes the buffer's `rowsPainted` dict back into a 2D grid.
5. Diffs against a golden `.txt` file under
  `Tests/SwiftLMTUITests/Snapshots/<TabName>_<Scenario>.txt`.

Goldens are regenerated with `SNAPSHOT_UPDATE=1 swift test --filter Snapshot`
(or `make snapshot-update`). Reviewers see the visual diff on every PR.

This catches: layout regressions, cell-shift bugs, label changes, color/style
drift (escape sequences appear verbatim in the rowsPainted strings).

### Layer 2: binary launch integration tests

`Tests/IntegrationTests/TUILaunchTests.swift` adds one test per TUI binary
that:

1. Locates the binary via `$SWIFTBENCH_BINARY_DIR` or
  `.build/release/<binary>`.
2. Spawns with `Process()`, pipes stdout to a buffer.
3. Waits up to 2s for the process to write **any** bytes (proof of render).
4. Sends `SIGINT`.
5. Asserts clean exit within 2s with an expected exit code.
6. Asserts the captured bytes contain the top-bar marker substring
  (e.g. `▌ swiftlmui`, `▌ swiftbench`): confirms the alt-screen paint
   actually executed, not just a stray log write.

This catches: binary-level crashes, signal handling regressions, main-loop
wire-up breaks. Does not test layout (that's Layer 1's job).

### Coverage matrix


| Binary    | Launch test | Panel snapshots                                                                                                        |
| --------- | ----------- | ---------------------------------------------------------------------------------------------------------------------- |
| swiftlmui | yes         | via MonitorTab, LibraryTab, ChatTab snapshots                                                                          |
| swifttop  | yes         | deferred (render pipeline is inlined in main.swift; covering it requires refactoring to expose a pure render function) |


`swifttop` snapshot coverage is tracked as a follow-up task. Its launch
test catches the "binary boots and paints" case immediately; layout
regressions there remain a gap until the render function is extracted.

## TODO:

- Testing that the terminal emulator honors our escape sequences.
We trust macOS Terminal / iTerm2 / alacritty to implement VT100+.
- Mouse input testing under real PTY. Unit-tested via
`MouseParserTests`.
- Resize (SIGWINCH) testing under real PTY. The fallback path in  
`Screen.currentSize` returns a constant, which the snapshot test  
uses as its input; we trust `ioctl(TIOCGWINSZ)` to work.

