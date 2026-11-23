# STEM ↔ Ghostty parity roadmap

Baseline reviewed 2026-11-08 against Ghostty's official
[feature overview](https://ghostty.org/docs/features),
[shell-integration guide](https://ghostty.org/docs/features/shell-integration),
[configuration reference](https://ghostty.org/docs/config/reference), and
[project roadmap](https://github.com/ghostty-org/ghostty#roadmap-and-status).

Ghostty parity means matching its standards, speed, modern protocols, and
platform-native quality—not copying its interface. STEM remains Krypton-first
and also treats Windows as a first-class platform.

## Current matrix

| Capability | Ghostty target | STEM macOS | STEM Linux | STEM Windows | Next milestone |
|---|---|---:|---:|---:|---|
| Common VT/ANSI + truecolor | Complete xterm-oriented coverage | Strong | Strong | Baseline | Shared conformance corpus |
| DEC margins, origin mode, insert/delete | Yes | Yes | Yes (shared core) | Partial | Expand DEC mode tests |
| Alternate screen / cursor / bracketed paste | Yes | Yes | Yes | Yes | Expand protocol tests |
| Scrollback + find | Yes | Yes | Yes | Yes | Prompt navigation |
| Selection + clipboard | Rich word/line/command selection | Yes | Yes | Viewport word/line selection | Cross-history selection |
| Mouse + focus reporting | Yes | Yes: SGR 1006 + focus | Yes (shared core) | Not yet | Windows mouse/focus events |
| Multiple windows / tabs / splits | Yes | Yes: windows, tabs, two-pane splits | Basic 2-pane splits (vert/horiz), focus/close; no tabs yet | Tabs + nested splits | Tabs, layout persistence, richer split management |
| Resize / reflow | Stable pixel and cell resizing | Cell resize; no text reflow | Cell resize | Cell resize | Shared reflow model and stress tests |
| Persistent configuration / themes | Extensive | Yes + settings helper + hot reload | Yes + easy `~/.config/stem/stem.conf`, keybinds, history, plugin config | Yes + settings GUI | Shared schema + named themes |
| Native UI | SwiftUI/AppKit + GTK | Cocoa | Wayland | WPF | Preserve native platform surfaces |
| Rendering | Metal / OpenGL | Custom view + attributed text | CPU framebuffer | CPU WPF | Krypton-owned cell renderer; then GPU backends |
| Heavy-output reliability | Production hardened | Hardening in progress | Untested at parity load | Untested at parity load | Deterministic progress-output soak tests |
| Grapheme clusters / emoji | Yes | Partial | Partial | Partial | Shared width/grapheme engine |
| Ligatures / font features | Yes | Native-font partial | No | Native-font partial | Shaping abstraction |
| OSC 8 hyperlinks / OSC 52 clipboard | Yes | Partial URL handling | Scaffold: OSC 52 policy hook, hyperlink config | No | Full OSC 8 metadata + OSC 52 policy in engine |
| Synchronized output | Yes | No | No | No | DEC mode 2026 frame transactions |
| Kitty keyboard protocol | Yes | No | No | No | Parser/input protocol phase |
| Kitty graphics protocol | Yes | No | No | No | Image store + GPU texture path |
| Shell integration | Prompt/CWD/command metadata, SSH helpers | No | Partial: OSC 7 CWD, OSC 133 mark detection, command history, shell env hooks, plugin events | No | Full OSC 133 prompt semantics, command duration/status, jump-to-prompt |
| Quick terminal / automation / restoration | Yes on macOS | No | Partial: control file/stemctl, session state save/restore, command palette/history overlay | No | Full session restoration, tabs/splits layouts, quick terminal |
| Extensions / plugins | Limited / evolving | No | Yes: executable hook plugins, event protocol, config-driven wiring | No | Stable plugin API + more events |
| Secure keyboard entry / accessibility | Native platform integration | No | No | Partial native accessibility | macOS secure input + accessibility audit |
| Embeddable terminal core | `libghostty` | Internal core | `stem_core.k` wrapper API (feed/render/cursor/meta/scrollback) | Temporary duplicate | Stable Krypton terminal-core ABI + PTY/session API |

## Delivery order

### P0 — daily-driver parity

1. Make macOS heavy-output handling crash-free with repeatable progress-bar,
   package-install, malformed-UTF-8, resize, split, and autocomplete soak tests.
2. Replace the macOS attributed-string terminal surface with a Krypton-owned
   fixed cell grid. Keep only a thin native window/event shell initially.
3. Complete Windows scrollback, selection, clipboard, mouse/focus reporting,
   configuration, and persisted tab/pane layouts.
4. Bring Linux window/tab/split organization up to the macOS frontend.

### P1 — compatibility parity

1. Build a shared VT conformance corpus derived from ECMA-48, xterm behavior,
   and protocol-origin tests.
2. Add grapheme clustering, Unicode width tables, combining marks, emoji ZWJ,
   and RTL-safe cluster storage while retaining an LTR terminal layout.
3. Add OSC 8, guarded OSC 52, synchronized output, styled underlines, palette
   queries, and light/dark notifications.
4. Add shell integration for PowerShell, zsh, bash, fish, and nushell: working
   directory, prompt marks, command boundaries, and close-at-prompt detection.

### P2 — performance parity

1. Define a renderer-neutral Krypton display-list API so `term.k` is the only
   terminal state engine.
2. Add Metal/CoreText on macOS, Direct3D/DirectWrite on Windows, and
   OpenGL/Vulkan on Linux behind that API. Objective-K owns the public surface;
   platform APIs remain isolated adapters.
3. Separate PTY read, parser, render preparation, and presentation scheduling;
   add frame coalescing and benchmark fixtures.
4. Profile memory layout, scrollback compression, parser throughput, latency,
   and large-output behavior before applying low-level optimization.

### P3 — modern graphics and native polish

1. Kitty graphics with bounded image storage and GPU texture lifecycle.
2. Ligatures and configurable font features.
3. Settings UI, theme browser, session restoration, quick terminal, automation,
   crash reporting, and platform-native accessibility.
4. Publish the stable Krypton terminal core as an embeddable library.

## macOS rendering direction

The immediate goal is not a full replacement for Apple's AppKit. Public macOS
window creation, menus, accessibility, input methods, and lifecycle remain
valuable and stable. STEM will instead remove terminal state and text layout
from AppKit objects:

1. `term.k` owns every cell, style, cursor, selection, and scrollback record.
2. A Krypton renderer consumes an immutable display snapshot; malformed or
   incomplete UTF-8 is replaced before it reaches platform text APIs.
3. The native view owns only presentation and input-event forwarding.
4. CoreText/CoreGraphics is the first backend; Metal follows after correctness
   and soak-test baselines are stable.
5. The reusable runtime and widgets can later become `libobjk`/KryptonKit.

This removes the current `NSAttributedString` hot path without depending on
private WindowServer interfaces or attempting an all-at-once AppKit clone.

## Architecture rule

No parity work may regress `stem.ks`, `stem_wl.ks`, or `term.k`. `term.k` is the
canonical parser/grid; the macOS build must not silently ship its older embedded
copy. New platform bridges stay isolated until Krypton/Objective-K can absorb
them. Behavioral fixes move into the shared core whenever possible. Every
renderer must survive sustained output, fragmented escape sequences, malformed
UTF-8, live resize, and split-pane stress before being marked complete.



## Current Linux/Hyprland status

Implemented in `stem_wl.ks` / `config.k`:
- Plaintext + flat JSON config (`stem.conf` / `stem.json`), XDG discovery, includes/theme/profile merge, validation.
- 2-pane splits (vertical/horizontal), focus/close/swap/grow/shrink/equalize, layout persistence in session file.
- Command history overlay, command palette, plugin hooks, `stemctl` control plane.
- OSC 7 cwd, OSC 133 prompt marks, OSC 52 policy hook, OSC 8 link marking, DEC 2026 basic buffering, basic Kitty CSI-u encoding.
- Session restore, debug/fps/perf overlays, Hyprland rules/desktop/control hooks.
- `stem_core.k` embeddable core wrapper API.

Still incomplete for full Ghostty parity:
- Wayland tabs and multi-split layout engine.
- GPU renderer backend.
- Font shaping/ligatures/fallback/grapheme clusters/emoji ZWJ.
- Full OSC 8 URL storage/round-trip, full Kitty keyboard protocol, full DEC 2026 engine semantics, image protocols.
- Full libghostty-equivalent stable ABI/PTY/session embedding.
