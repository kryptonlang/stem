# stem — Krypton-first cross-platform terminal

STEM is a cross-platform terminal emulator built around Krypton. The canonical
terminal engine and the macOS and Linux window paths remain pure Krypton. The
Windows desktop preview is deliberately isolated under `windows/`: it uses a
small .NET/WPF + ConPTY bridge while Objective-K's Windows backend catches up,
and is designed to move back into Krypton without disturbing the other
platforms.

## Platform status

- **macOS:** working pure-Krypton Cocoa terminal with live zsh, truecolor,
  scrollback, selection, tabs, splits, mouse reporting, and full-screen TUIs.
- **Linux:** pure-Krypton Wayland/Hyprland frontend in `stem_wl.ks`, backed by
  the shared `term.k` grid and native PTY builtins.
- **Windows:** interactive ConPTY preview with a Krypton-themed desktop frame,
  PowerShell-first shell selection, VT/truecolor rendering, resize, keyboard
  input, and bracketed paste. The managed bridge is temporary and Windows-only.

```text
                         term.k — canonical Krypton terminal engine
                                      |
             +------------------------+------------------------+
             |                        |                        |
       stem.ks (macOS)          stem_wl.ks (Linux)       windows/ (Windows)
       Cocoa / Objective-K      Wayland / Krypton        WPF + ConPTY bridge
```

## Install (macOS, Apple Silicon)

```bash
brew tap t3m3d/krypton          # once
brew install stem           # the `stem` command -> run it to open a window
brew install --cask stem    # OR a clickable stem.app in /Applications
```

The cask app is ad-hoc signed (not notarized) — first launch, right-click → Open
(or `xattr -dr com.apple.quarantine /Applications/stem.app`).

Self-contained — no krypton runtime dependency. A
[JetBrainsMono Nerd Font](https://www.nerdfonts.com/) is recommended for the
powerline/icon glyphs (configurable in `~/.config/stem/stem.conf`).

## Build from source

Requires Krypton **2.5.0-alpha** or newer (`kcc --version`). Older toolchains
miscompile enum payloads (e.g. `Event::Foo(x)`); stem's TUI core relies on
them heavily.

### macOS

The build scripts are KryptScript (`.ks`, run with `kcc -r`), not shell.

```bash
kcc -r build_objk.ks   # -> dist/stem.app (pure Krypton, no Obj-C source)
open dist/stem.app
```

`build_objk.ks` compiles `stem.ks` straight to a Cocoa app through the
Objective-K FFI. The result links only `libobjc`, Foundation, and AppKit.

Optional: build against the Krypton Binary Interface (KBI) fast ABI instead
of the classic FFI bridge (macOS arm64 only, opt-in):

```bash
kcc -r build_objk.ks --kbi
# or, for backwards compatibility: STEMBUILD_KBI=1 kcc -r build_objk.ks
```

This passes `--kbi` to the frontend; the generated `stem.kir` carries a
`; KBI: 1` marker and the codegen seeds `rBUMP` (x28) plus KBI variants of
`__rt_alloc` and the foreign-call marshalling. The two flavors never clobber
each other: the default build stays at `dist/stem.app`, the KBI build lands
in `dist/kbi/stem.app`.

**KBI is experimental.** The KBI code path requires a macho codegen host
built from the current `macho_arm64_self.k` backend; the classic prebuilt
seed host ignores the marker and produces a classic binary. On some
toolchain revisions the KBI app fails to launch at all. To avoid shipping a
crashing bundle, `--kbi` builds are smoke-checked: the app is launched and
must stay alive for ~15 seconds, otherwise the build fails loudly and the
broken bundle is removed. Set `STEM_SKIP_SMOKE=1` to skip the check (not
recommended).

### Developing with socam

[`socam`](https://github.com/t3m3d/socam) (the Krypton assistance CLI) works
against this repo out of the box:

```bash
socam list .                    # enumerate the .k sources (term.k, ansi.k, ...)
socam explain term.k            # IR stats + full IR for the VT grid engine
socam explain run.k > /tmp/ir   # capture IR to a file for review
socam grep "gridFeed" term.k    # literal line search
socam watch run.ks stem-cli     # rebuild + relaunch the CLI bridge on save
```

Set `KRYPTON_ROOT=/path/to/krypton` (or have `/usr/local/krypton` installed)
so socam can find `compiler/macos_arm64/kcc-arm64`. socam is local-only — no
network, no AI backends.

A running stem instance can also be driven through socam's live IPC bridge —
opt-in only, since the notification channel is user-session wide:

```bash
STEM_SOCAM_BRIDGE=1 open dist/stem.app        # launch with the bridge armed
socam repl dump                               # windows/panes/secure-entry + master fd
socam repl status                             # health check: stem version + active pane count
socam repl border                             # force a full repaint of every pane
socam repl reload                             # reload ~/.config/stem/stem.conf
socam repl quit                               # terminate gracefully
```

Without `STEM_SOCAM_BRIDGE=1` the bridge is not installed and stem behaves
exactly as before. (Requires socam ≥ 0.6.0 with the `sleepUs` argument-order
fix in `core/repl.k`, otherwise `repl` blocks in the reply poll.)

### Linux (Hyprland / Wayland)

STEM's Linux frontend is a pure-Krypton Wayland terminal (`stem_wl.ks`) focused on Hyprland/Kryptos workflows.

```bash
kcc -r stem_wl.ks                    # run Wayland frontend directly
kcc -r build_linux.ks --wl           # build ./stem-wl native ELF
kcc -r build_linux.ks                # build ./stem CLI engine
```

Linux keybinds (configurable): `Ctrl+Shift+D` split right, `Ctrl+Shift+E` split down, `Ctrl+Shift+O` focus next pane, `Ctrl+Shift+X` close pane, `Ctrl+Shift+S` swap panes, `Ctrl+Shift+P` command palette, `Ctrl+Shift+H` history, `Ctrl+Shift+R` reload config, `Ctrl+Shift+I` open config, `F11` fullscreen.

Hyprland integration snippet: `contrib/hyprland/stem-rules.conf`. Desktop entry: `contrib/stem.desktop`. Control plane: `contrib/stemctl` (`stemctl reload`, `stemctl doctor`, `stemctl send ...`). Embeddable core wrapper: `stem_core.k`.

### Windows

The usable desktop preview requires Windows 10 version 1809 or newer and the
.NET 8 SDK:

```powershell
.\windows\build.ps1 -Test
dotnet run --project .\windows\Stem.Windows\Stem.Windows.csproj
```

The older `kcc -r build_windows.ks` path remains the pure-Krypton Win32
prototype. It is preserved for Objective-K/backend work; the isolated preview
under `windows/` supplies the persistent ConPTY terminal in the meantime.
See `windows/README.md` for the migration boundary and shell override.

## Shipping (cask DMG)

```bash
kcc -r build_dmg.ks                    # VERSION → dist/stem-<version>.dmg
```

`build_dmg.ks` reads the release number from `VERSION`, builds `stem.app` with
the released `kcc` (objk, no Obj-C),
**fails closed** if the app isn't C-free, then makes the compressed DMG the cask
ships. With Homebrew `krypton` >= 2.4.0 on PATH it needs no config; otherwise
point `KRYPTON_ROOT` at a krypton 2.4.0 install. It prints the sha256 + the
`gh release upload` / `Casks/stem.rb` bump to finish a release.

## Engine (pure Krypton)

- **`term.k`** — incremental ANSI grid driver. Packed-string state (char +
  fg/bg attr planes + cursor + scrollback). Handles CUP/CUU/…/EL/ED (param-aware),
  ESC7/8 + `ESC[s/u` cursor save/restore, deferred wrap (auto-margin), SGR
  256-colour **and** truecolor (`48;2;r;g;b` → nearest xterm-256), multi-byte
  UTF-8 single-column cells, scroll with scrollback capture, OSC 0/2 title,
  find (`gridFind`).
- **`run.k -i`** — interactive bridge. Spawns the shell on a pty (native
  `ptyMaster`/`ptyForkExec`/`fdRead`/`fdWrite`/`fdSetNonblock`/`sleepUs`), feeds
  output through the grid, coalesces settled frames, and emits each as
  `SOH header SOH grid \f`. Reads keystrokes + control markers (resize / scroll /
  clear / find) back on stdin.
- **`pty.k`** — pty wrapper. **`ansi.k`** — standalone `stripAnsi`.
- **`stem.ks`** — the pure-Krypton Cocoa GUI on the **objk** FFI: `NSWindow`,
  custom `NSView` `drawRect:` (renders the `term.k` grid), `keyDown:` → pty,
  `NSTimer`/event-pump read loop, menus. No Obj-C source; see *Build from source*.

## Shortcuts

| Key | Action |
|---|---|
| ⌘C / ⌘V / ⌘A | copy selection / bracketed paste / select all |
| ⌘F · ⌘G · ⌘⇧G | find in scrollback · next · prev |
| ⌘K | clear screen + scrollback |
| ⌘N / ⌘T | new window / new tab |
| ⌘D / ⌘⇧D | split right / split down (File menu: also left / up) |
| ⌘W / ⌘⇧W / ⌘⌥W | close pane / close window / close all |
| ⌘Q | quit |
| ⌘+ / ⌘− / ⌘0 | font zoom in / out / reset |
| ⌘↑ / ⌘↓ | scrollback page up / down |
| ⌘Home / ⌘End | scrollback top / back to live |
| scroll wheel | scrollback |
| drag · 2-click · 3-click | select · word · line |
| ⌘-click · middle-click | open URL · paste |

## Config

STEM uses easy plaintext config by default, with optional flat JSON for more structured setups:

- **Default:** `~/.config/stem/stem.conf` (easy `key = value`, `#` comments)
- **JSON:** `~/.config/stem/stem.json` or `config.json` (flat object; keys/values same as conf)
- **Override:** `STEM_CONF=/absolute/path/to/stem.conf|stem.json`
- **XDG:** respects `$XDG_CONFIG_HOME/stem/...`

STEM creates a default config on first launch when missing. Canonical templates: [`stem.conf`](stem.conf) and [`contrib/config/stem.json`](contrib/config/stem.json).

```ini
# Window / Hyprland
title = STEM
app_id = stem
cols = 120
rows = 32
padding = 10
opacity = 0.95

# Shell / session
shell = /bin/zsh
working_directory = ~
term = xterm-256color
command_history = true
history_file = ~/.config/stem/history

# Keybindings
bind.copy = ctrl+shift+c
bind.paste = ctrl+shift+v
bind.reload_config = ctrl+shift+r
bind.command_history = ctrl+shift+h

# Plugins
plugins_enabled = true
plugin_dir = ~/.config/stem/plugins
```

### Plugins / extensions

Plugins are executable hooks in `~/.config/stem/plugins/`. STEM emits events (`startup`, `command`, `bell`, `history_request`) with env vars and stdin payload; plugins can respond with stdout commands (`notify:`, `open:`, `write_pty:`, `reload_config`). See [`contrib/plugins/README.md`](contrib/plugins/README.md).

### Command history

When `command_history = true`, STEM records entered commands to `history_file` (default `~/.config/stem/history`) with timestamps. `Ctrl+Shift+H` opens the history overlay; `Ctrl+Shift+P` opens the command palette.

### Automation / diagnostics

- `control_file` + `contrib/stemctl` provide a simple control plane (`reload`, `quit`, `notify`, `title`, `send`, `doctor`).
- `debug_overlay` / `fps_overlay` / `perf_log` expose runtime diagnostics.
- `restore_session` saves basic session state on exit.

Frontends safely ignore keys they do not implement on that platform.

`⌘A` selects all · `⌘-click` opens underlined URLs · ⇧PageUp/Down also scrolls.

## Why this exists

Krypton's goal is to escape the C/C++/Qt runtime stack with compact native
programs. STEM demonstrates that with a portable Krypton terminal engine and
pure-Krypton macOS and Linux frontends. Windows currently keeps its temporary
ConPTY/WPF bridge behind a strict platform boundary so the application is useful
today and can be converted to Objective-K as Windows support matures.

## License

MIT — see [LICENSE](LICENSE).
