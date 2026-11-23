// stem_wl.ks — stem's Wayland/Hyprland windowed frontend (pure Krypton).
//
// MVP: host stem's terminal engine (PTY + VT grid) inside a k:wayland window.
// Reuses: k:wayland (surface + software framebuffer + 8x16 font + keyboard),
// stem term.k (VT/grid), stem pty.k (PTY), stem config.k (stem.conf).
//
// This is the .ks orchestration layer — the perf-critical grid/VT/PTY live in
// the imported compiled .k modules; the event loop + wiring live here.
//
// Run:  kcc -r stem_wl.ks    (needs a running Wayland compositor, e.g. Hyprland)

import "k:wayland"
import "./term.k"      // gridNew / gridFeed / gridRender
import "./pty.k"       // ptyMaster / ptySlaveName / ptyForkExec / fd*
import "./config.k"    // confLoad / confGet / confGetInt
import "./stemfont.k"  // stemFontLoad / stemDrawChar (extended glyphs)

// Find a wl_registry global's `name` by interface (registry obj=2, global op=0).
// (Local helper — k:wayland exposes the wire getters but not this scan.)
func _wlFind(b, n, iface) {
    let off = 0
    while off + 8 <= n {
        let sz = wlSize(b, off)
        if sz < 8 { emit -1 }
        if wlObject(b, off) == 2 && wlOpcode(b, off) == 0 {
            if wlReadStr(b, off + 12) == iface { emit wlU32(b, off + 8) }
        }
        off = off + sz
    }
    emit -1
}

// ── minimal keysym(keycode) -> bytes for the shell ───────────────────────────
// X11 keycodes (wlKeyToKc = evdev+8). Covers printable ASCII via a layout row
// map + the essential control keys. Full keymap/layout = future.
// X11-vestige (future-edit item): kc is an X11 keycode (evdev+8), not an evdev
// code — migrate keycode grid to native evdev or xkbcommon keysyms if this
// table is ever extended; see brain/linux/display.k and cortex_wl.k for the
// identical pattern. Not an X11 dependency (no X protocol); constants only.
func kKeyBytes(kc, shift, ctrl, alt, kitty) {
    let enter = fromCharCode(13)
    let bs = fromCharCode(127)
    let tab = fromCharCode(9)
    let esc = fromCharCode(27)
    // Kitty keyboard protocol (CSI u) - basic encoding when enabled
    if kitty == 1 {
        let mods = 1
        if shift == 1 { mods = mods + 1 }
        if alt == 1 { mods = mods + 2 }
        if ctrl == 1 { mods = mods + 4 }
        if mods > 1 {
            let ch = kCharOf(kc, shift)
            if ch != "" {
                let cp = toInt(charCode(ch))
                if cp >= 97 && cp <= 122 { cp = cp - 32 } // uppercase codepoint
                emit esc + "[" + cp + ";" + mods + "u"
            }
        }
    }
    if kc == 36 { emit enter }          // Return
    if kc == 22 { emit bs }             // Backspace
    if kc == 23 { emit tab }            // Tab
    if kc == 9  { emit esc }            // Escape
    // arrows -> ANSI CSI
    if kc == 111 { emit esc + "[A" }    // Up
    if kc == 116 { emit esc + "[B" }    // Down
    if kc == 114 { emit esc + "[C" }    // Right
    if kc == 113 { emit esc + "[D" }    // Left
    // navigation / editing keys
    if kc == 110 { emit esc + "[H" }    // Home
    if kc == 115 { emit esc + "[F" }    // End
    if kc == 112 { emit esc + "[5~" }   // Page Up
    if kc == 117 { emit esc + "[6~" }   // Page Down
    if kc == 118 { emit esc + "[2~" }   // Insert
    if kc == 119 { emit esc + "[3~" }   // Delete
    // function keys F1-F12 (xterm: F1-F4 = SS3, F5-F12 = CSI ~)
    if kc == 67 { emit esc + "OP" }     // F1
    if kc == 68 { emit esc + "OQ" }     // F2
    if kc == 69 { emit esc + "OR" }     // F3
    if kc == 70 { emit esc + "OS" }     // F4
    if kc == 71 { emit esc + "[15~" }   // F5
    if kc == 72 { emit esc + "[17~" }   // F6
    if kc == 73 { emit esc + "[18~" }   // F7
    if kc == 74 { emit esc + "[19~" }   // F8
    if kc == 75 { emit esc + "[20~" }   // F9
    if kc == 76 { emit esc + "[21~" }   // F10
    if kc == 95 { emit esc + "[23~" }   // F11
    if kc == 96 { emit esc + "[24~" }   // F12
    // printable via keyChar layout (shared shape with cortex)
    let ch = kCharOf(kc, shift)
    if ch != "" {
        if ctrl == 1 {                  // Ctrl-A..Ctrl-Z -> 0x01..0x1A
            let cc = toInt(charCode(ch))
            if cc >= 97 && cc <= 122 { emit fromCharCode((cc - 96) + "") }
        }
        if alt == 1 { emit esc + ch }   // Alt/Meta -> ESC-prefixed (word-move, etc.)
        emit ch
    }
    emit ""
}

// keycode -> character for the US layout home/number rows (MVP subset).
// X11-vestige (future-edit item): kc is an X11 keycode grid (evdev+8), not an
// evdev code. Migrate with xkbcommon if this map grows past US layout; constants
// only, no X11 dependency. See cortex_wl.k / brain/linux/display.k.
func kCharOf(kc, shift) {
    // letters: kc 24..33 = q..p ; 38..46 = a..; 52..58 = z.. ; use a table string.
    let row1 = "qwertyuiop"    // kc 24..33
    let row2 = "asdfghjkl"     // kc 38..46
    let row3 = "zxcvbnm"       // kc 52..58
    let nums = "1234567890"    // kc 10..19
    let symN = "!@#$%^&*()"    // shifted numbers
    if kc >= 24 && kc <= 33 { emit kShiftAlpha(substring(row1, kc - 24, kc - 23), shift) }
    if kc >= 38 && kc <= 46 { emit kShiftAlpha(substring(row2, kc - 38, kc - 37), shift) }
    if kc >= 52 && kc <= 58 { emit kShiftAlpha(substring(row3, kc - 52, kc - 51), shift) }
    if kc >= 10 && kc <= 19 { if shift == 1 { emit substring(symN, kc - 10, kc - 9) }  emit substring(nums, kc - 10, kc - 9) }
    if kc == 65 { emit " " }            // Space
    if kc == 20 { if shift == 1 { emit "_" }  emit "-" }
    if kc == 21 { if shift == 1 { emit "+" }  emit "=" }
    if kc == 51 { if shift == 1 { emit "|" }  emit fromCharCode(92) }   // backslash
    if kc == 47 { if shift == 1 { emit ":" }  emit ";" }
    if kc == 48 { if shift == 1 { emit fromCharCode(34) }  emit "'" }
    if kc == 59 { if shift == 1 { emit "<" }  emit "," }
    if kc == 60 { if shift == 1 { emit ">" }  emit "." }
    if kc == 61 { if shift == 1 { emit "?" }  emit "/" }
    emit ""
}
func kShiftAlpha(c, shift) {
    if shift == 1 { emit toUpper(c) }
    emit c
}

// write a pasted clipboard string to the pty, wrapping it in bracketed-paste
// markers (ESC[200~ … ESC[201~) when the app enabled DECSET 2004 — keeps vim &
// friends from auto-indenting the pasted block.
func kSendPaste(m, clip, meta) {
    if len(clip) <= 0 { emit 0 }
    if gridPasteM(meta) == 1 {
        let e = fromCharCode(27)
        let w = e + "[200~" + clip + e + "[201~"
        fdWrite(m, w, len(w))
    } else {
        fdWrite(m, clip, len(clip))
    }
    emit 0
}

// encode a mouse event for the app: SGR 1006 (ESC[<b;col;row;M/m, msgr==1) or the
// legacy X10 form (ESC[M b+32 col+32 row+32). col/row are 0-based here.
func kMouseSeq(msgr, btn, col, row, press) {
    let e = fromCharCode(27)
    if msgr == 1 {
        let tm = "M"  if press == 0 { tm = "m" }
        emit e + "[<" + btn + ";" + (col + 1) + ";" + (row + 1) + tm
    }
    let cc = col + 33  if cc > 255 { cc = 255 }
    let rr = row + 33  if rr > 255 { rr = 255 }
    let lb = btn  if press == 0 { lb = 3 }     // legacy: any release = button 3
    emit e + "[M" + fromCharCode(lb + 32) + fromCharCode(cc) + fromCharCode(rr)
}

// xterm-256 colour index (0..255) -> packed 0xRRGGBB.
func xterm256rgb(idx) {
    // base-16: One Dark palette (readable on a dark bg — the VGA defaults made
    // ANSI blue 0x000080 etc. unreadable). black raised to a dark grey so black
    // text isn't invisible.
    if idx == 0  { emit 3883080 }    if idx == 1  { emit 14707829 }  // black(grey), red
    if idx == 2  { emit 10011513 }   if idx == 3  { emit 15057019 }  // green, yellow
    if idx == 4  { emit 6402031 }    if idx == 5  { emit 13007069 }  // blue, magenta
    if idx == 6  { emit 5682882 }    if idx == 7  { emit 11252415 }  // cyan, white
    if idx == 8  { emit 6054768 }    if idx == 9  { emit 14707829 }  // br.grey, br.red
    if idx == 10 { emit 10011513 }   if idx == 11 { emit 15057019 }  // br.green, br.yellow
    if idx == 12 { emit 6402031 }    if idx == 13 { emit 13007069 }  // br.blue, br.magenta
    if idx == 14 { emit 5682882 }    if idx == 15 { emit 16777215 }  // br.cyan, br.white
    if idx >= 232 { let v = 8 + (idx - 232) * 10  emit v * 65536 + v * 256 + v }  // greyscale ramp
    let n = idx - 16                  // 6x6x6 colour cube
    let r = n / 36  let g = (n - r * 36) / 6  let b = n - r * 36 - g * 6
    let rv = 0  if r > 0 { rv = 55 + r * 40 }
    let gv = 0  if g > 0 { gv = 55 + g * 40 }
    let bv = 0  if b > 0 { bv = 55 + b * 40 }
    emit rv * 65536 + gv * 256 + bv
}
// ── mutable 256-colour palette (OSC 4 can override entries) ──────────────────
// 3 bytes (R,G,B) per index. Seeded from xterm256rgb; OSC 4 rewrites entries.
func palInit() {
    let pal = bufNew(768)
    let i = 0
    while i < 256 {
        let rgb = xterm256rgb(i)
        let r = rgb / 65536  let g = (rgb - r * 65536) / 256  let b = rgb - r * 65536 - g * 256
        bufSetByte(pal, i * 3, r)  bufSetByte(pal, i * 3 + 1, g)  bufSetByte(pal, i * 3 + 2, b)
        i = i + 1
    }
    emit pal
}
func palRGB(pal, idx) {
    let o = idx * 3
    emit toInt(bufGetByte(pal, o)) * 65536 + toInt(bufGetByte(pal, o + 1)) * 256 + toInt(bufGetByte(pal, o + 2))
}
func palSet(pal, idx, rgb) {
    if idx < 0 || idx > 255 { emit 0 }
    let r = rgb / 65536  let g = (rgb - r * 65536) / 256  let b = rgb - r * 65536 - g * 256
    bufSetByte(pal, idx * 3, r)  bufSetByte(pal, idx * 3 + 1, g)  bufSetByte(pal, idx * 3 + 2, b)
    emit 0
}

func _isHexCh(c) { if (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) { emit 1 }  emit 0 }

// parse an OSC colour spec ("#RRGGBB", "#RRRRGGGGBBBB", "rgb:rr/gg/bb") -> rgb, -1 if not.
func parseOscColor(spec) {
    let h = indexOf(spec, "#")
    if h >= 0 {
        let raw = substring(spec, h + 1, len(spec))
        let e = 0
        while e < len(raw) && _isHexCh(toInt(charCode(substring(raw, e, e + 1)))) == 1 { e = e + 1 }
        let hex = substring(raw, 0, e)
        if len(hex) >= 12 { emit hexColor(substring(hex, 0, 2) + substring(hex, 4, 6) + substring(hex, 8, 10), 0) }
        if len(hex) >= 6 { emit hexColor(substring(hex, 0, 6), 0) }
        emit 0 - 1
    }
    let r = indexOf(spec, "rgb:")
    if r >= 0 {
        let body = substring(spec, r + 4, len(spec))
        let p1 = indexOf(body, "/")
        if p1 < 0 { emit 0 - 1 }
        let cr = substring(body, 0, p1)
        let rest = substring(body, p1 + 1, len(body))
        let p2 = indexOf(rest, "/")
        if p2 < 0 { emit 0 - 1 }
        let cg = substring(rest, 0, p2)
        let cb = substring(rest, p2 + 1, len(rest))
        emit hexColor(substring(cr, 0, 2) + substring(cg, 0, 2) + substring(cb, 0, 2), 0)
    }
    emit 0 - 1
}

// Parse OSC 7 cwd (file://host/path) -> path or "".
func osc7Cwd(s) {
    let n = len(s)
    let i = 0
    let cwd = ""
    while i + 1 < n {
        if toInt(charCode(substring(s, i, i + 1))) == 27 && toInt(charCode(substring(s, i + 1, i + 2))) == 93 {
            let bstart = i + 2
            let j = bstart
            let term = 0
            while j < n && term == 0 {
                let cj = toInt(charCode(substring(s, j, j + 1)))
                if cj == 7 { term = 1 }
                else { if cj == 27 && j + 1 < n && toInt(charCode(substring(s, j + 1, j + 2))) == 92 { term = 1 }
                else { j = j + 1 } }
            }
            let body = substring(s, bstart, j)
            if j < n && toInt(charCode(substring(s, j, j + 1))) == 7 { i = j + 1 } else { i = j + 2 }
            if len(body) > 2 && substring(body, 0, 2) == "7;" {
                let uri = substring(body, 2, len(body))
                let pfx = "file://"
                let k = indexOf(uri, pfx)
                if k >= 0 {
                    let rest = substring(uri, k + 7, len(uri))
                    let slash = indexOf(rest, "/")
                    if slash >= 0 { cwd = substring(rest, slash, len(rest)) }
                }
            }
        } else { i = i + 1 }
    }
    emit cwd
}

// Parse OSC 133 prompt marks. Returns "A", "B", "C", "D;<status>", or "".
func osc133Event(s) {
    let n = len(s)
    let i = 0
    let ev = ""
    while i + 1 < n {
        if toInt(charCode(substring(s, i, i + 1))) == 27 && toInt(charCode(substring(s, i + 1, i + 2))) == 93 {
            let bstart = i + 2
            let j = bstart
            let term = 0
            while j < n && term == 0 {
                let cj = toInt(charCode(substring(s, j, j + 1)))
                if cj == 7 { term = 1 }
                else { if cj == 27 && j + 1 < n && toInt(charCode(substring(s, j + 1, j + 2))) == 92 { term = 1 }
                else { j = j + 1 } }
            }
            let body = substring(s, bstart, j)
            if j < n && toInt(charCode(substring(s, j, j + 1))) == 7 { i = j + 1 } else { i = j + 2 }
            if len(body) > 4 && substring(body, 0, 4) == "133;" {
                ev = substring(body, 4, len(body))
            }
        } else { i = i + 1 }
    }
    emit ev
}

// DEC 2026 synchronized output: detect CSI ? 2026 h/l. Returns 1=set, -1=reset, 0=no change.
func dec2026Mode(s) {
    let n = len(s)
    let i = 0
    let mode = 0
    while i + 1 < n {
        if toInt(charCode(substring(s, i, i + 1))) == 27 && toInt(charCode(substring(s, i + 1, i + 2))) == 91 {
            let j = i + 2
            let params = ""
            let fin = 0
            while j < n && fin == 0 {
                let cj = toInt(charCode(substring(s, j, j + 1)))
                if cj >= 64 && cj <= 126 { fin = cj }
                else { params = params + substring(s, j, j + 1) }
                j = j + 1
            }
            if (fin == 104 || fin == 108) && indexOf(params, "?2026") >= 0 {
                if fin == 104 { mode = 1 } else { mode = 0 - 1 }
            }
            i = j
        } else { i = i + 1 }
    }
    emit mode
}

// OSC 52 clipboard write: ESC ] 52 ; c ; <base64> BEL/ST. Policy: allow|ask|deny.
func osc52Apply(s, policy) {
    if policy == "deny" { emit 0 }
    let n = len(s)
    let i = 0
    while i + 1 < n {
        if toInt(charCode(substring(s, i, i + 1))) == 27 && toInt(charCode(substring(s, i + 1, i + 2))) == 93 {
            let bstart = i + 2
            let j = bstart
            let term = 0
            while j < n && term == 0 {
                let cj = toInt(charCode(substring(s, j, j + 1)))
                if cj == 7 { term = 1 }
                else { if cj == 27 && j + 1 < n && toInt(charCode(substring(s, j + 1, j + 2))) == 92 { term = 1 }
                else { j = j + 1 } }
            }
            let body = substring(s, bstart, j)
            if j < n && toInt(charCode(substring(s, j, j + 1))) == 7 { i = j + 1 } else { i = j + 2 }
            if len(body) > 4 && substring(body, 0, 4) == "52;" {
                let rest = substring(body, 4, len(body))
                let semi = indexOf(rest, ";")
                let payload = rest
                if semi >= 0 { payload = substring(rest, semi + 1, len(rest)) }
                if payload != "?" && payload != "" {
                    if policy == "allow" {
                        let tmp = "/tmp/.stem-osc52.b64"
                        writeFile(tmp, payload)
                        exec("base64 -d \"" + tmp + "\" 2>/dev/null | wl-copy >/dev/null 2>&1 &")
                    } else {
                        exec("notify-send -a stem 'OSC 52 clipboard blocked' 'Set osc52_clipboard=allow to permit' >/dev/null 2>&1 &")
                    }
                }
            }
        } else { i = i + 1 }
    }
    emit 0
}

// scan a chunk for OSC 4 / 10 / 11 / 12; apply OSC 4 to `pal` (in place); return
// "fg,bg,cursor" rgb ints from the last 10/11/12 (-1 = unchanged).
func oscApply(s, pal) {
    let fgC = 0 - 1  let bgC = 0 - 1  let curC = 0 - 1
    let n = len(s)
    let i = 0
    while i + 1 < n {
        if toInt(charCode(substring(s, i, i + 1))) == 27 && toInt(charCode(substring(s, i + 1, i + 2))) == 93 {
            let bstart = i + 2
            let j = bstart
            let term = 0
            while j < n && term == 0 {
                let cj = toInt(charCode(substring(s, j, j + 1)))
                if cj == 7 { term = 1 }
                else { if cj == 27 && j + 1 < n && toInt(charCode(substring(s, j + 1, j + 2))) == 92 { term = 1 }
                else { j = j + 1 } }
            }
            let body = substring(s, bstart, j)
            if j < n && toInt(charCode(substring(s, j, j + 1))) == 7 { i = j + 1 } else { i = j + 2 }
            let semi = indexOf(body, ";")
            if semi > 0 {
                let ps = substring(body, 0, semi)
                let rest = substring(body, semi + 1, len(body))
                if ps == "10" { let c = parseOscColor(rest)  if c >= 0 { fgC = c } }
                if ps == "11" { let c = parseOscColor(rest)  if c >= 0 { bgC = c } }
                if ps == "12" { let c = parseOscColor(rest)  if c >= 0 { curC = c } }
                if ps == "4" {
                    let r2 = rest  let scan = 1
                    while scan == 1 {
                        let s1 = indexOf(r2, ";")
                        if s1 < 0 { scan = 0 }
                        else {
                            let idx = toInt(substring(r2, 0, s1))
                            let after = substring(r2, s1 + 1, len(r2))
                            let s2 = indexOf(after, ";")
                            let colStr = after
                            if s2 >= 0 { colStr = substring(after, 0, s2)  r2 = substring(after, s2 + 1, len(after)) }
                            else { scan = 0 }
                            let col = parseOscColor(colStr)
                            if col >= 0 { palSet(pal, idx, col) }
                        }
                    }
                }
            }
        } else { i = i + 1 }
    }
    emit fgC + "," + bgC + "," + curC
}

// Scan a chunk for terminal QUERIES the program waits on, and return the bytes to
// write back to the pty. Without these, fish/zsh/ncurses stall before the prompt:
//   ESC[6n  DSR cursor position -> ESC[<row>;<col>R
//   ESC[c / ESC[0c  DA1 -> ESC[?1;2c   ;   ESC[>c  DA2 -> ESC[>1;10;0c
func termReplies(s, meta, cols, rows) {
    let e = fromCharCode(27)
    let reply = ""
    let n = len(s)
    let i = 0
    while i + 1 < n {
        if toInt(charCode(substring(s, i, i + 1))) == 27 && toInt(charCode(substring(s, i + 1, i + 2))) == 91 {
            let j = i + 2
            let params = ""
            let fin = 0
            while j < n && fin == 0 {
                let cj = toInt(charCode(substring(s, j, j + 1)))
                if cj >= 64 && cj <= 126 { fin = cj }
                else { params = params + substring(s, j, j + 1) }
                j = j + 1
            }
            if fin == 110 && params == "6" {                       // DSR cursor position
                let cur = gridCursorM(meta)
                let cm = indexOf(cur, ",")
                let cr = toInt(substring(cur, 0, cm)) + 1
                let cc = toInt(substring(cur, cm + 1, len(cur))) + 1
                if cr < 1 || cr > rows { cr = 1 }
                if cc < 1 || cc > cols { cc = 1 }
                reply = reply + e + "[" + cr + ";" + cc + "R"
            }
            if fin == 99 {                                         // DA
                if params == "" || params == "0" { reply = reply + e + "[?1;2c" }       // DA1
                else { if substring(params, 0, 1) == ">" { reply = reply + e + "[>1;10;0c" } }  // DA2
            }
            if fin == 116 {                                        // 't' window manipulation
                if params == "18" { reply = reply + e + "[8;" + rows + ";" + cols + "t" }       // text-area size (chars)
                if params == "14" { reply = reply + e + "[4;" + (rows * 16) + ";" + (cols * 8) + "t" }  // size (px)
            }
            i = j
        } else { i = i + 1 }
    }
    emit reply
}

// attr/battr cell byte -> rgb. <=1 = default (use `def`); >=2 = palette[byte-2].
func kColorOf(byteVal, def, pal) {
    if byteVal <= 1 { emit def }
    emit palRGB(pal, byteVal - 2)
}

// parse a hex colour string ("CCFFCC" / "#CCFFCC" / "0xCCFFCC") -> 0xRRGGBB; def if blank.
func hexColor(s, def) {
    if s == "" { emit def }
    let h = s
    if len(h) >= 2 && substring(h, 0, 2) == "0x" { h = substring(h, 2, len(h)) }
    if len(h) >= 1 && substring(h, 0, 1) == "#" { h = substring(h, 1, len(h)) }
    let v = 0
    let i = 0
    while i < len(h) {
        let c = toInt(charCode(substring(h, i, i + 1)))
        let d = 0 - 1
        if c >= 48 && c <= 57 { d = c - 48 }
        if c >= 97 && c <= 102 { d = c - 87 }
        if c >= 65 && c <= 70 { d = c - 55 }
        if d >= 0 { v = v * 16 + d }
        i = i + 1
    }
    emit v
}

// strip trailing spaces from one line (terminal selection copies rtrimmed rows).
func rtrimLine(s) {
    let n = len(s)
    while n > 0 && substring(s, n - 1, n) == " " { n = n - 1 }
    emit substring(s, 0, n)
}

// row-major slice of one line from column a (inclusive) to b (exclusive), clamped.
func kRowSlice(line, a, b) {
    let ln = len(line)
    let lo = a   if lo < 0 { lo = 0 }   if lo > ln { lo = ln }
    let hi = b   if hi < 0 { hi = 0 }   if hi > ln { hi = ln }
    if hi <= lo { emit "" }
    emit substring(line, lo, hi)
}

// extract selected text from the live grid for range (sr,sc)..(er,ec), inclusive
// of the end cell. Multi-row joins with '\n'; each row is rtrimmed.
func kSelText(gb, cols, rows, sr, sc, er, ec) {
    let r1 = sr  let c1 = sc  let r2 = er  let c2 = ec
    if r1 > r2 || (r1 == r2 && c1 > c2) {     // normalize so (r1,c1) precedes (r2,c2)
        r1 = er  c1 = ec  r2 = sr  c2 = sc
    }
    let text = gridPlainB(gb, cols, rows)
    if r1 == r2 { emit rtrimLine(kRowSlice(getLine(text, r1), c1, c2 + 1)) }
    let out = rtrimLine(kRowSlice(getLine(text, r1), c1, cols))
    let r = r1 + 1
    while r < r2 {
        out = out + fromCharCode(10) + rtrimLine(getLine(text, r))
        r = r + 1
    }
    out = out + fromCharCode(10) + rtrimLine(kRowSlice(getLine(text, r2), 0, c2 + 1))
    emit out
}

// is cell (r,c) inside the inclusive linear selection (sr,sc)..(er,ec)?
func kInSel(r, c, cols, sr, sc, er, ec) {
    let r1 = sr  let c1 = sc  let r2 = er  let c2 = ec
    if r1 > r2 || (r1 == r2 && c1 > c2) { r1 = er  c1 = ec  r2 = sr  c2 = sc }
    let pos = r * cols + c
    let lo = r1 * cols + c1
    let hi = r2 * cols + c2
    if pos >= lo && pos <= hi { emit 1 }
    emit 0
}

// UTF-8: byte count of a sequence from its lead byte, and codepoint decode.
// The grid is one CELL per column but a cell may hold a multibyte glyph, so the
// renderer must walk the row by character (not byte) to keep columns aligned.
func kUtf8Len(b) {
    if b < 128 { emit 1 }
    if b < 224 { emit 2 }
    if b < 240 { emit 3 }
    emit 4
}
func kUtf8Cp(s, i, cl) {
    let b0 = toInt(charCode(substring(s, i, i + 1)))
    if cl == 1 { emit b0 }
    if cl == 2 {
        let b1 = toInt(charCode(substring(s, i + 1, i + 2)))
        emit (b0 - 192) * 64 + (b1 - 128)
    }
    if cl == 3 {
        let b1 = toInt(charCode(substring(s, i + 1, i + 2)))
        let b2 = toInt(charCode(substring(s, i + 2, i + 3)))
        emit (b0 - 224) * 4096 + (b1 - 128) * 64 + (b2 - 128)
    }
    let c1 = toInt(charCode(substring(s, i + 1, i + 2)))
    let c2 = toInt(charCode(substring(s, i + 2, i + 3)))
    let c3 = toInt(charCode(substring(s, i + 3, i + 4)))
    emit (b0 - 240) * 262144 + (c1 - 128) * 4096 + (c2 - 128) * 64 + (c3 - 128)
}
// decode the codepoint stored in a grid cell (buffer gb, byte offset off, width w).
func kCellCp(gb, off, w) {
    let b0 = toInt(bufGetByte(gb, off + 1))
    if w == 1 { emit b0 }
    if w == 2 { emit (b0 - 192) * 64 + (toInt(bufGetByte(gb, off + 2)) - 128) }
    if w == 3 { emit (b0 - 224) * 4096 + (toInt(bufGetByte(gb, off + 2)) - 128) * 64 + (toInt(bufGetByte(gb, off + 3)) - 128) }
    let c1 = toInt(bufGetByte(gb, off + 2))  let c2 = toInt(bufGetByte(gb, off + 3))  let c3 = toInt(bufGetByte(gb, off + 4))
    emit (b0 - 240) * 262144 + (c1 - 128) * 4096 + (c2 - 128) * 64 + (c3 - 128)
}

// codepoint of the col-th character in a UTF-8 line (32 = space if past the end)
func kCharAtCol(line, col) {
    let n = len(line)
    let bi = 0
    let c = 0
    while bi < n {
        let lead = toInt(charCode(substring(line, bi, bi + 1)))
        let cl = kUtf8Len(lead)
        if bi + cl > n { cl = n - bi }
        if c == col { emit kUtf8Cp(line, bi, cl) }
        bi = bi + cl
        c = c + 1
    }
    emit 32
}

// ── render: stem grid -> framebuffer, per-cell ANSI colour. Block cursor; bell. ──
func kDrawScreen(px, W, H, font, gb, ab, bb, ub, meta, cols, rows, bg, fg, bell, curColor, curStyle, hasSel, selSR, selSC, selER, selEC, pal, padX, padY, ox, oy, pw, ph, selBg, selFg, linkColor) {
    let back = bg
    if bell == 1 { back = 3355494 }                 // visual-bell flash
    fbFillRect(px, W, ox, oy, pw, ph, back)
    // read every cell straight from the plane buffers — no per-frame string alloc.
    let r = 0
    while r < rows {
        let c = 0
        while c < cols {
            let idx = r * cols + c
            let off = idx * 5
            let x = ox + padX + c * 8  let y = oy + padY + r * 16
            let cellFg = kColorOf(toInt(bufGetByte(ab, idx)), fg, pal)
            let cellBg = kColorOf(toInt(bufGetByte(bb, idx)), back, pal)
            if hasSel == 1 && kInSel(r, c, cols, selSR, selSC, selER, selEC) == 1 {
                cellBg = selBg
                if selFg != 0 { cellFg = selFg }
            }
            if cellBg != back { fbFillRect(px, W, x, y, 8, 16, cellBg) }
            let w = toInt(bufGetByte(gb, off))
            let chcode = kCellCp(gb, off, w)
            let ubv = toInt(bufGetByte(ub, idx))
            let hasUl = 0
            if ubv - (ubv / 2) * 2 == 1 { hasUl = 1 }
            let hasLink = 0
            if ubv >= 2 { hasLink = 1  if hasUl == 0 { hasUl = 1 }  cellFg = linkColor }
            if chcode != 32 { stemDrawChar(px, W, H, font, x, y, chcode, cellFg) }
            if hasUl == 1 { fbFillRect(px, W, x, y + 14, 8, 1, cellFg) }
            c = c + 1
        }
        r = r + 1
    }
    // cursor at gridCursor row,col
    let cur = gridCursorM(meta)
    let comma = indexOf(cur, ",")
    let cr = toInt(substring(cur, 0, comma))
    let cc = toInt(substring(cur, comma + 1, len(cur)))
    if cr >= 0 && cr < rows && cc >= 0 && cc < cols {
        let cx = ox + padX + cc * 8  let cy = oy + padY + cr * 16
        let coff = (cr * cols + cc) * 5
        let cglyph = kCellCp(gb, coff, toInt(bufGetByte(gb, coff)))   // cursor cell glyph (from buffer)
        let cstyle = curStyle                            // app DECSCUSR overrides the config default
        let appShape = gridCshapeM(meta)
        if appShape == 1 { cstyle = 1 }                 // bar
        if appShape == 2 { cstyle = 0 }                 // block
        if appShape == 3 { cstyle = 2 }                 // underline
        if cstyle == 1 {                                // bar: 2px at cell left, glyph normal
            fbFillRect(px, W, cx, cy, 2, 16, curColor)
            if cglyph != 32 { stemDrawChar(px, W, H, font, cx, cy, cglyph, fg) }
        } else {
            if cstyle == 2 {                            // underline: 2px at cell bottom, glyph normal
                fbFillRect(px, W, cx, cy + 14, 8, 2, curColor)
                if cglyph != 32 { stemDrawChar(px, W, H, font, cx, cy, cglyph, fg) }
            } else {                                    // block: fill cell, glyph inverted
                fbFillRect(px, W, cx, cy, 8, 16, curColor)
                if cglyph != 32 { stemDrawChar(px, W, H, font, cx, cy, cglyph, back) }
            }
        }
    }
}

// scrollback view: history + live grid, offset up by scrollOff lines (monochrome —
// scrolled-off rows are stored as plain text). A "▲" marks we're not at the bottom.
func kDrawScrollback(px, W, H, font, scrollback, gb, cols, rows, scrollOff, bg, fg, padX, padY, ox, oy, pw, ph) {
    fbFillRect(px, W, ox, oy, pw, ph, bg)
    let view = gridScrollView(scrollback, gridPlainB(gb, cols, rows), rows, scrollOff)
    let r = 0
    while r < rows {
        let line = gridStripSgr(getLine(view, r))
        fbDrawText(px, W, H, font, ox + padX, oy + padY + r * 16, line, fg)
        r = r + 1
    }
    fbDrawText(px, W, H, font, ox + pw - 60, oy + padY, "^" + scrollOff, 16776960)
}

// ── config helpers ───────────────────────────────────────────────────────────
func kConfStr(conf, key, def) { emit confGet(conf, key, def) }
func kConfInt(conf, key, def) { emit confGetInt(conf, key, def) }
func kConfBool(conf, key, def) { emit confGetBool(conf, key, def) }

func kDefaultShell() {
    let sh = environ("SHELL")
    if sh != "" { emit sh }
    emit "/bin/bash"
}

func kLower(s) {
    let out = ""
    let i = 0
    let n = len(s)
    while i < n {
        let c = toInt(charCode(substring(s, i, i + 1)))
        if c >= 65 && c <= 90 { out = out + fromCharCode((c + 32) + "") }
        else { out = out + substring(s, i, i + 1) }
        i = i + 1
    }
    emit out
}

func kExpandPath(p) { emit confExpandPath(p) }

// ── keybinding parsing ───────────────────────────────────────────────────────
// Bind spec: "ctrl+shift+c", "shift+pageup", "ctrl+plus". Returns "1" on match.
func kBindMatch(spec, kc, shift, ctrl, alt) {
    let s = kLower(trim(spec))
    if s == "" { emit 0 }
    let wantShift = 0  let wantCtrl = 0  let wantAlt = 0
    let key = s
    // parse modifiers
    let done = 0
    while done == 0 {
        if len(key) >= 6 && substring(key, 0, 6) == "shift+" { wantShift = 1  key = substring(key, 6, len(key)) }
        else { if len(key) >= 5 && substring(key, 0, 5) == "ctrl+" { wantCtrl = 1  key = substring(key, 5, len(key)) }
        else { if len(key) >= 4 && substring(key, 0, 4) == "alt+" { wantAlt = 1  key = substring(key, 4, len(key)) }
        else { if len(key) >= 6 && substring(key, 0, 6) == "super+" { wantAlt = 1  key = substring(key, 6, len(key)) }
        else { done = 1 } } } }
    }
    if wantShift != shift || wantCtrl != ctrl || wantAlt != alt { emit 0 }
    // key name -> keycode (X11 keycodes, evdev+8)
    let wantKc = 0 - 1
    if key == "pageup" || key == "pgup" { wantKc = 112 }
    if key == "pagedown" || key == "pgdn" { wantKc = 117 }
    if key == "home" { wantKc = 110 }
    if key == "end" { wantKc = 115 }
    if key == "plus" || key == "=" || key == "+" { wantKc = 21 }
    if key == "minus" || key == "-" { wantKc = 20 }
    if key == "0" { wantKc = 19 }
    if key == "enter" || key == "return" { wantKc = 36 }
    if key == "esc" || key == "escape" { wantKc = 9 }
    if key == "tab" { wantKc = 23 }
    if key == "space" { wantKc = 65 }
    if key == "backspace" { wantKc = 22 }
    // single letter a-z
    if wantKc < 0 && len(key) == 1 {
        let c = toInt(charCode(key))
        if c >= 97 && c <= 122 {
            // map letter to X11 keycode via rows in kCharOf
            let row1 = "qwertyuiop"  let row2 = "asdfghjkl"  let row3 = "zxcvbnm"
            let ri = 0
            while ri < 10 { if substring(row1, ri, ri + 1) == key { wantKc = 24 + ri }  ri = ri + 1 }
            ri = 0
            while ri < 9 { if substring(row2, ri, ri + 1) == key { wantKc = 38 + ri }  ri = ri + 1 }
            ri = 0
            while ri < 7 { if substring(row3, ri, ri + 1) == key { wantKc = 52 + ri }  ri = ri + 1 }
        }
        if c >= 48 && c <= 57 { wantKc = 10 + (c - 48) } // 1..9,0 not perfect but close
    }
    if wantKc < 0 { emit 0 }
    if kc == wantKc { emit 1 }
    emit 0
}

func kBindAction(conf, action, kc, shift, ctrl, alt) {
    let spec = confGet(conf, "bind." + action, "")
    if spec == "" { emit 0 }
    emit kBindMatch(spec, kc, shift, ctrl, alt)
}

// ── plugin hooks ─────────────────────────────────────────────────────────────
// Simple, language-agnostic plugin protocol:
//   executable files in plugin_dir receive env vars + payload on stdin.
//   stdout lines may contain commands: notify:, open:, write_pty:, set_title:, reload_config
func kPluginEmit(pluginDir, enabled, event, payload, confPathVal, format) {
    if enabled != 1 { emit "" }
    let dir = kExpandPath(pluginDir)
    if dir == "" { emit "" }
    let listing = exec("ls -1 \"" + dir + "\" 2>/dev/null")
    if trim(listing) == "" { emit "" }
    let body = payload
    if format == "json" {
        body = "{\"event\":\"" + event + "\",\"payload\":\"" + payload + "\"}"
    }
    let outAll = ""
    let n = lineCount(listing)
    let i = 0
    while i < n {
        let name = trim(getLine(listing, i))
        if name != "" && name != "manifest.toml" {
            let path = dir + "/" + name
            let isExec = trim(exec("test -x \"" + path + "\" && echo yes || echo no"))
            if isExec == "yes" {
                let cmd = "env STEM_EVENT=\"" + event + "\" STEM_CONFIG=\"" + confPathVal + "\" STEM_PLUGIN_DIR=\"" + dir + "\" STEM_VERSION=\"0.1.0\" STEM_EVENT_FORMAT=\"" + format + "\" \"" + path + "\""
                let tmp = "/tmp/.stem-plugin-in"
                writeFile(tmp, body)
                let pOut = exec(cmd + " < \"" + tmp + "\" 2>/dev/null")
                if trim(pOut) != "" {
                    if outAll == "" { outAll = pOut } else { outAll = outAll + fromCharCode(10) + pOut }
                }
            }
        }
        i = i + 1
    }
    emit outAll
}

func kPluginApplyCommands(out, m, confPathVal) {
    // returns "reload" or "quit" or "", else action string
    if trim(out) == "" { emit "" }
    let n = lineCount(out)
    let i = 0
    let action = ""
    while i < n {
        let line = trim(getLine(out, i))
        if len(line) > 7 && substring(line, 0, 7) == "notify:" {
            let msg = trim(substring(line, 7, len(line)))
            exec("notify-send -a stem stem \"" + msg + "\" >/dev/null 2>&1 &")
        }
        if len(line) > 5 && substring(line, 0, 5) == "open:" {
            let target = trim(substring(line, 5, len(line)))
            exec("xdg-open \"" + target + "\" >/dev/null 2>&1 &")
        }
        if len(line) > 10 && substring(line, 0, 10) == "write_pty:" {
            let txt = substring(line, 10, len(line))
            fdWrite(m, txt, len(txt))
        }
        if len(line) > 10 && substring(line, 0, 10) == "set_title:" {
            action = line
        }
        if line == "reload_config" { action = "reload" }
        if line == "quit" || line == "close" { action = "quit" }
        i = i + 1
    }
    emit action
}

func kHyprctl(enabled, args) {
    if enabled != 1 { emit "" }
    let sig = environ("HYPRLAND_INSTANCE_SIGNATURE")
    if sig == "" { emit "" }
    emit exec("hyprctl " + args + " >/dev/null 2>&1")
}

func kPerfLog(enabled, path, line) {
    if enabled != 1 { emit 0 }
    let p = kExpandPath(path)
    if p == "" { emit 0 }
    confEnsureParent(p)
    let tmp = "/tmp/.stem-perf-row"
    writeFile(tmp, line + fromCharCode(10))
    exec("cat \"" + tmp + "\" >> \"" + p + "\" 2>/dev/null")
    emit 0
}

func kControlPoll(controlFile, enabled, m, confPathVal) {
    // File-based control plane: commands written to control_file are consumed.
    if enabled != 1 { emit "" }
    let p = kExpandPath(controlFile)
    if p == "" { emit "" }
    let raw = readFile(p)
    if trim(raw) == "" { emit "" }
    writeFile(p, "")  // consume
    emit kPluginApplyCommands(raw, m, confPathVal)
}

// ── command history ──────────────────────────────────────────────────────────
func kHistoryAppend(historyFile, enabled, line) {
    if enabled != 1 { emit 0 }
    let p = kExpandPath(historyFile)
    if p == "" { emit 0 }
    let t = trim(line)
    if t == "" { emit 0 }
    confEnsureParent(p)
    // Append with timestamp prefix: epoch\tcommand
    let ts = trim(exec("date +%s 2>/dev/null"))
    if ts == "" { ts = "0" }
    let row = ts + fromCharCode(9) + t + fromCharCode(10)
    // append via shell - Krypton writeFile overwrites; append is easiest via exec.
    let tmp = "/tmp/.stem-hist-row"
    writeFile(tmp, row)
    exec("cat \"" + tmp + "\" >> \"" + p + "\" 2>/dev/null")
    emit 0
}

func kHistoryLoad(historyFile, maxEntries) {
    let p = kExpandPath(historyFile)
    if p == "" { emit "" }
    let raw = readFile(p)
    if raw == "" { emit "" }
    // Return last maxEntries lines as plain commands (strip timestamp).
    let n = lineCount(raw)
    let start = 0
    if n > maxEntries { start = n - maxEntries }
    let out = ""
    let i = start
    while i < n {
        let line = trim(getLine(raw, i))
        if line != "" {
            let tab = indexOf(line, fromCharCode(9))
            let cmd = line
            if tab >= 0 && tab < 20 { cmd = substring(line, tab + 1, len(line)) }
            if out == "" { out = cmd } else { out = out + fromCharCode(10) + cmd }
        }
        i = i + 1
    }
    emit out
}

func kSpawnPane(shell, term, workDir, loginShell, shellIntegration, confPathVal) {
    let m = ptyMaster("/dev/ptmx")
    let slave = ptySlaveName(m)
    let nl = fromCharCode(10)
    let wrapPath = "/tmp/.stem-shell-" + m
    let wrap = "#!/bin/sh" + nl
    wrap = wrap + "export TERM=" + term + nl
    wrap = wrap + "export COLORTERM=truecolor" + nl
    wrap = wrap + "export STEM_VERSION=0.1.0" + nl
    wrap = wrap + "export STEM_CONFIG=\"" + confPathVal + "\"" + nl
    if shellIntegration == 1 { wrap = wrap + "export STEM_SHELL_INTEGRATION=1" + nl }
    if workDir != "" { wrap = wrap + "cd \"" + workDir + "\" 2>/dev/null" + nl }
    if loginShell == 1 { wrap = wrap + "exec " + shell + " -l" + nl }
    else { wrap = wrap + "exec " + shell + nl }
    writeFile(wrapPath, wrap)
    exec("chmod +x " + wrapPath + " 2>/dev/null")
    let pid = ptyForkExec(slave, wrapPath)
    ptySetNonblock(m)
    emit "" + m + "," + pid
}

func kOverlayFilter(items, query) {
    let q = kLower(trim(query))
    if q == "" { emit items }
    let out = ""
    let n = lineCount(items)
    let i = 0
    while i < n {
        let line = getLine(items, i)
        if line != "" {
            let ll = kLower(line)
            if indexOf(ll, q) >= 0 {
                if out == "" { out = line } else { out = out + fromCharCode(10) + line }
            }
        }
        i = i + 1
    }
    emit out
}

func kOverlayDraw(px, W, H, font, title, items, query, sel) {
    let boxW = W - 80
    if boxW < 200 { boxW = W - 20 }
    let boxH = 280
    if boxH > H - 40 { boxH = H - 40 }
    let x = (W - boxW) / 2
    let y = 20
    fbFillRect(px, W, x, y, boxW, boxH, 1710618)       // dark panel
    fbFillRect(px, W, x, y, boxW, 24, 2500134)          // header
    fbDrawText(px, W, H, font, x + 8, y + 4, title + "  " + query, 16777215)
    let maxRows = (boxH - 40) / 16
    let n = lineCount(items)
    if sel < 0 { sel = 0 }
    if sel >= n && n > 0 { sel = n - 1 }
    let start = 0
    if sel >= maxRows { start = sel - maxRows + 1 }
    let r = 0
    while r < maxRows {
        let idx = start + r
        if idx < n {
            let line = getLine(items, idx)
            let yy = y + 30 + r * 16
            if idx == sel { fbFillRect(px, W, x + 4, yy - 1, boxW - 8, 16, 3756378) }
            fbDrawText(px, W, H, font, x + 8, yy, line, 13434828)
        }
        r = r + 1
    }
    emit 0
}

just run {
    // ── config ──
    let confPathVal = confPath()
    confEnsureDir(confDir())
    confEnsureDir(confDir() + "/plugins")
    confEnsureDir(confDir() + "/themes")
    confEnsureDir(confDir() + "/profiles")
    let conf = confLoadMerged()
    if conf == "" {
        // First launch: write the bundled/default config template next to confPath.
        let tmpl = readFile("stem.conf")
        if tmpl == "" { tmpl = readFile("/usr/share/stem/stem.conf") }
        if tmpl != "" { confEnsureParent(confPathVal)  writeFile(confPathVal, tmpl)  conf = tmpl }
    }

    let shellRaw = trim(confGetAny(conf, "shell", "shell_command", ""))
    let shell = shellRaw
    if shell == "" { shell = kDefaultShell() }
    let term = confGet(conf, "term", "xterm-256color")
    let workDir = kExpandPath(confGetAny(conf, "working_directory", "cwd", "~"))
    let restoreSession = confGetBool(conf, "restore_session", 1)
    let sessionFile = confGet(conf, "session_file", "~/.config/stem/session.conf")
    let restoreSplitMode = 0
    let restoreSplitRatio = 50
    let restoreActivePane = 0
    if restoreSession == 1 {
        let sdat = readFile(kExpandPath(sessionFile))
        if workDir == "" || workDir == environ("HOME") {
            let scwd = confGet(sdat, "cwd", "")
            if scwd != "" { workDir = scwd }
        }
        restoreSplitMode = confGetInt(sdat, "split_mode", 0)
        restoreSplitRatio = confGetInt(sdat, "split_ratio", 50)
        restoreActivePane = confGetInt(sdat, "active_pane", 0)
        if restoreSplitRatio < 20 { restoreSplitRatio = 20 }
        if restoreSplitRatio > 80 { restoreSplitRatio = 80 }
    }
    let loginShell = confGetBool(conf, "login_shell", 0)
    let shellIntegration = confGetBool(conf, "shell_integration", 1)

    let bg = hexColor(confGetAny(conf, "background", "bg", ""), 1054753)         // 0x101821 dark
    let fg = hexColor(confGetAny(conf, "foreground", "fg", ""), 13434828)        // 0xCCFFCC soft green
    let curColor = hexColor(confGet(conf, "cursor_color", ""), fg)
    let selBg = hexColor(confGet(conf, "selection_background", ""), 3756378)
    let selFg = hexColor(confGet(conf, "selection_foreground", ""), 0)
    let linkColor = hexColor(confGet(conf, "link_color", ""), 8847615)
    let curStyleS = confGet(conf, "cursor_style", "block")      // block | bar | underline
    let curStyle = 0
    if curStyleS == "bar" { curStyle = 1 }
    if curStyleS == "underline" { curStyle = 2 }
    let bellMode = confGet(conf, "bell", "visual")             // visual | off
    let copyOnSelect = confGetBool(conf, "copy_on_select", 0)
    let confirmClose = confGetBool(conf, "confirm_close", 0)
    let scrollMult = confGetIntAny(conf, "scroll_multiplier", "mouse_scroll_multiplier", 3)
    if scrollMult < 1 { scrollMult = 1 }  if scrollMult > 20 { scrollMult = 20 }

    let pad = confGetInt(conf, "padding", 4)
    if pad < 0 { pad = 0 }  if pad > 64 { pad = 64 }
    let padX = confGetInt(conf, "padding_x", pad)
    let padY = confGetInt(conf, "padding_y", pad)
    if padX < 0 { padX = 0 }  if padX > 64 { padX = 64 }
    if padY < 0 { padY = 0 }  if padY > 64 { padY = 64 }

    let appId = confGet(conf, "app_id", "stem")
    let winTitle = confGetAny(conf, "title", "window_title", "STEM")
    let pluginsEnabled = confGetBool(conf, "plugins_enabled", 1)
    let pluginDir = confGet(conf, "plugin_dir", "~/.config/stem/plugins")
    let pluginEventFormat = confGet(conf, "plugin_event_format", "text")
    let historyEnabled = confGetBool(conf, "command_history", 1)
    let historyFile = confGet(conf, "history_file", "~/.config/stem/history")
    let historyMax = confGetInt(conf, "history_max_entries", 10000)
    let controlEnabled = confGetBool(conf, "control_enabled", 1)
    let controlFile = confGet(conf, "control_file", "~/.config/stem/ctl")
    let debugOverlay = confGetBool(conf, "debug_overlay", 0)
    let fpsOverlay = confGetBool(conf, "fps_overlay", 0)
    let perfLog = confGetBool(conf, "perf_log", 0)
    let perfLogFile = confGet(conf, "perf_log_file", "~/.config/stem/perf.log")
    let hyprlandIpc = confGetBool(conf, "hyprland_ipc", 1)
    let osc52Policy = confGet(conf, "osc52_clipboard", "ask")
    let kittyKeyboard = confGetBool(conf, "kitty_keyboard", 0)
    let hyperlinksEnabled = confGetBool(conf, "hyperlinks", 1)
    let syncOutputEnabled = confGetBool(conf, "synchronized_output", 1)
    let graphemeClusters = confGetBool(conf, "grapheme_clusters", 0)
    let ligaturesEnabled = confGetBool(conf, "ligatures_enabled", 0)
    let fontFallback = confGetBool(conf, "font_fallback", 1)
    let rendererMode = confGet(conf, "renderer", "cpu")
    let maxFps = confGetInt(conf, "max_fps", 120)
    let vsync = confGetBool(conf, "vsync", 1)
    let mouseHideTyping = confGetBool(conf, "mouse_hide_while_typing", 1)
    let searchWrap = confGetBool(conf, "search_wrap", 1)
    let searchCase = confGetBool(conf, "search_case_sensitive", 0)
    let initialCmd = confGet(conf, "initial_command", "")
    let fullscreen = confGetBool(conf, "fullscreen", 0)
    confEnsureDir(kExpandPath(pluginDir))
    confEnsureParent(kExpandPath(historyFile))
    confEnsureParent(kExpandPath(controlFile))

    // initial size from config grid (a tiling compositor may override on map).
    let cfgCols = confGetInt(conf, "cols", 120)
    let cfgRows = confGetInt(conf, "rows", 32)
    if cfgCols < 20 { cfgCols = 20 }   if cfgCols > 400 { cfgCols = 400 }
    if cfgRows < 5  { cfgRows = 5 }    if cfgRows > 200 { cfgRows = 200 }
    let W = cfgCols * 8 + padX * 2  let H = cfgRows * 16 + padY * 2
    let cols = (W - padX * 2) / 8
    let rows = (H - padY * 2) / 16

    // ── pty + shell FIRST, BEFORE wlConnect ──
    // The shell is forked here; if we connected to Wayland first, the forked
    // child would inherit the Wayland socket fd and keep the compositor
    // connection (and thus the window) alive after stem exits — orphan
    // zombie windows that ignore close. Forking before connect avoids that.
    let m = ptyMaster("/dev/ptmx")
    let slave = ptySlaveName(m)
    // ptyForkExec inherits stem's environment; launch through a tiny wrapper so
    // we can export TERM/COLORTERM, set cwd, and optionally mark login shell.
    let nl = fromCharCode(10)
    let wrapPath = "/tmp/.stem-shell-" + m
    let wrap = "#!/bin/sh" + nl
    wrap = wrap + "export TERM=" + term + nl
    wrap = wrap + "export COLORTERM=truecolor" + nl
    wrap = wrap + "export STEM_VERSION=0.1.0" + nl
    wrap = wrap + "export STEM_CONFIG=\"" + confPathVal + "\"" + nl
    if shellIntegration == 1 {
        wrap = wrap + "export STEM_SHELL_INTEGRATION=1" + nl
    }
    if workDir != "" { wrap = wrap + "cd \"" + workDir + "\" 2>/dev/null" + nl }
    if loginShell == 1 { wrap = wrap + "exec " + shell + " -l" + nl }
    else { wrap = wrap + "exec " + shell + nl }
    writeFile(wrapPath, wrap)
    exec("chmod +x " + wrapPath + " 2>/dev/null")
    let childPid = ptyForkExec(slave, wrapPath)

    // ── wayland surface (child already forked: it has no Wayland fd) ──
    let fd = wlConnect()
    if fd < 0 { print("stem: wayland connect failed")  exit("1") }
    let REG = 2  let COMP = 3  let SHM = 4  let WM = 5  let SEAT = 6  let KB = 7  let PTR = 8
    let SURF = 9  let XS = 10  let TOP = 11   // sequential object ids, NO gaps
    wlGetRegistry(fd, REG)
    let rb = bufNew(8192)
    let SYNCB = 12
    let rn = wlSyncRegistry(fd, SYNCB, rb, 8192)
    if rn < 0 { print("stem: wayland registry handshake failed")  exit("1") }
    wlBind(fd, REG, _wlFind(rb, rn, "wl_compositor"), "wl_compositor", 4, COMP)
    wlBind(fd, REG, _wlFind(rb, rn, "wl_shm"), "wl_shm", 1, SHM)
    wlBind(fd, REG, _wlFind(rb, rn, "xdg_wm_base"), "xdg_wm_base", 1, WM)
    wlBind(fd, REG, _wlFind(rb, rn, "wl_seat"), "wl_seat", 5, SEAT)
    wlGetKeyboard(fd, SEAT, KB)
    wlGetPointer(fd, SEAT, PTR)
    wlCreateSurface(fd, COMP, SURF)
    wlGetXdgSurface(fd, WM, XS, SURF)
    wlGetToplevel(fd, XS, TOP)
    wlSetTitle(fd, TOP, winTitle)
    wlSetAppId(fd, TOP, appId)
    wlCommit(fd, SURF)

    let font = stemFontLoad()
    let tries = 0
    while tries < 60 { if ptySetSize(m, rows, cols) == 0 { tries = 60 } else { sleepUs(0, 10000)  tries = tries + 1 } }
    ptySetNonblock(m)
    fdSetNonblock(fd)                  // wayland fd: poll, don't block
    // persistent plane buffers (mutated in place by gridFeedB — no per-feed alloc)
    let gb = bufNew(5 * cols * rows)  let ab = bufNew(cols * rows)  let bb = bufNew(cols * rows)
    let ub = bufNew(cols * rows)      // per-cell underline plane (SGR 4)
    gridBlank(gb, ab, bb, ub, cols, rows)
    let meta = gridInitMeta()
    let pal = palInit()                // live 256-colour palette (OSC 4 overrides)

    // ── split/pane state (2 panes max for now) ──
    let splitMode = 0        // 0 none, 1 vertical (left/right), 2 horizontal (top/bottom)
    let paneCount = 1
    let activePane = 0
    let splitRatio = 50      // percent for pane 0
    let p0_m = m  let p0_pid = childPid  let p0_gb = gb  let p0_ab = ab  let p0_bb = bb  let p0_ub = ub  let p0_meta = meta
    let p0_cols = cols  let p0_rows = rows  let p0_scrollback = ""  let p0_scrollOff = 0  let p0_pending = ""  let p0_quiet = 0
    let p0_kicked = 0  let p0_kickIn = 0  let p0_kickArmed = 0  let p0_title = "stem"  let p0_inputLine = ""
    let p1_m = 0 - 1  let p1_pid = 0 - 1  let p1_gb = 0  let p1_ab = 0  let p1_bb = 0  let p1_ub = 0  let p1_meta = ""
    let p1_cols = cols  let p1_rows = rows  let p1_scrollback = ""  let p1_scrollOff = 0  let p1_pending = ""  let p1_quiet = 0
    let p1_kicked = 0  let p1_kickIn = 0  let p1_kickArmed = 0  let p1_title = "stem"  let p1_inputLine = ""

    // Plugin startup hook (non-fatal; stdout commands applied best-effort).
    let pStartup = kPluginEmit(pluginDir, pluginsEnabled, "startup", "app_id=" + appId + fromCharCode(10) + "title=" + winTitle, confPathVal, pluginEventFormat)
    let pStartupAct = kPluginApplyCommands(pStartup, m, confPathVal)
    if pStartupAct == "reload" { conf = confLoadMerged() }
    if initialCmd != "" { fdWrite(m, initialCmd + fromCharCode(10), len(initialCmd) + 1) }
    if fullscreen == 1 { kHyprctl(hyprlandIpc, "dispatch fullscreen 0") }
    if restoreSplitMode == 1 || restoreSplitMode == 2 {
        splitMode = restoreSplitMode  paneCount = 2  splitRatio = restoreSplitRatio  activePane = restoreActivePane
        if activePane != 0 && activePane != 1 { activePane = 0 }
        if splitMode == 1 {
            let p0w = ((W - padX * 2) * splitRatio / 100) / 8
            let p1w = ((W - padX * 2) - (p0w * 8) - 2) / 8
            if p0w < 10 { p0w = 10 }  if p1w < 10 { p1w = 10 }
            p0_cols = p0w  p0_rows = (H - padY * 2) / 16
            p1_cols = p1w  p1_rows = p0_rows
        } else {
            let p0h = ((H - padY * 2) * splitRatio / 100) / 16
            let p1h = ((H - padY * 2) - (p0h * 16) - 2) / 16
            if p0h < 4 { p0h = 4 }  if p1h < 4 { p1h = 4 }
            p0_cols = (W - padX * 2) / 8  p0_rows = p0h
            p1_cols = p0_cols  p1_rows = p1h
        }
        p0_gb = bufNew(5 * p0_cols * p0_rows)  p0_ab = bufNew(p0_cols * p0_rows)  p0_bb = bufNew(p0_cols * p0_rows)  p0_ub = bufNew(p0_cols * p0_rows)
        gridBlank(p0_gb, p0_ab, p0_bb, p0_ub, p0_cols, p0_rows)  p0_meta = gridInitMeta()  p0_scrollback = ""  p0_scrollOff = 0
        ptySetSize(p0_m, p0_rows, p0_cols)
        let sp = kSpawnPane(shell, term, workDir, loginShell, shellIntegration, confPathVal)
        let spc = indexOf(sp, ",")
        p1_m = toInt(substring(sp, 0, spc))  p1_pid = toInt(substring(sp, spc + 1, len(sp)))
        p1_gb = bufNew(5 * p1_cols * p1_rows)  p1_ab = bufNew(p1_cols * p1_rows)  p1_bb = bufNew(p1_cols * p1_rows)  p1_ub = bufNew(p1_cols * p1_rows)
        gridBlank(p1_gb, p1_ab, p1_bb, p1_ub, p1_cols, p1_rows)  p1_meta = gridInitMeta()  p1_scrollback = ""  p1_scrollOff = 0  p1_pending = ""  p1_quiet = 0  p1_title = "stem"
        ptySetSize(p1_m, p1_rows, p1_cols)
    }

    let shift = 0  let ctrl = 0  let alt = 0  let mouseHidden = 0
    let nextId = 13  let prevBuf = 0  let prevPool = 0  let prevMfd = 0
    let dirty = 1  let running = 1  let configured = 0
    let kicked = 0  let kickIn = 0  let kickArmed = 0   // debounced startup Ctrl-L once the shell settles
    let title = "stem"  let bell = 0
    let pending = ""        // partial escape/UTF-8 carried between reads
    let scrollback = ""     // lines that scrolled off the top (history)
    let quiet = 0           // consecutive empty reads (flush a buffered tail)
    let scrollOff = 0       // scrollback view offset (0 = live bottom)
    let sbCap = confGetIntAny(conf, "scrollback", "scrollback_lines", 10000)
    let inputLine = ""      // naive line buffer for command history capture
    let histOn = historyEnabled
    let histFilePath = historyFile
    let histMaxEntries = historyMax
    let osc133Enabled = confGetBool(conf, "shell_integration", 1)
    let currentCwd = workDir
    let promptMark = ""
    let cmdStartSeen = 0
    // mouse selection (live screen only): drag left button to select, release copies
    let selecting = 0  let hasSel = 0
    let closeArmed = 0
    let overlayMode = 0      // 0 none, 1 history, 2 palette
    let overlayQuery = ""
    let overlayItems = ""
    let overlaySel = 0
    let selSR = 0  let selSC = 0  let selER = 0  let selEC = 0
    let ptrR = 0   let ptrC = 0   let heldBtn = 0 - 1   // SGR button held for drag reporting (-1 none)
    let mousePane = 0
    let eb = bufNew(8192)              // reused every loop (was leaking 8KB/iteration)
    let ctlCtr = 0
    let frameCount = 0
    let outBytesTotal = 0
    let perfCtr = 0
    let syncOutput = 0
    let syncBuf = ""
    let fbMem = 0  let fbPx = 0  let fbPool = 0  let fbSz = 0   // shared framebuffer, reused across frames
    while running == 1 {
        // 1) drain wayland events (non-blocking)
        let en = wlRecvInto(fd, eb, 8192)
        let off = 0
        while off + 8 <= en {
            let obj = wlObject(eb, off)  let op = wlOpcode(eb, off)  let s = wlSize(eb, off)
            if s < 8 { off = en }
            else {
                if obj == WM && op == 0 { wlPong(fd, WM, wlU32(eb, off + 8)) }
                if obj == XS && op == 0 {
                    wlAckConfigure(fd, XS, wlU32(eb, off + 8))
                    // Arm a DEBOUNCED Ctrl-L: it fires ~240ms after the shell's
                    // startup output stops (each chunk resets kickIn below), so a
                    // slow shell reprints its prompt once into the final grid.
                    if configured == 0 { kickArmed = 1  kickIn = 30 }
                    configured = 1  dirty = 1
                }
                if obj == TOP && op == 0 {
                    let cw = wlU32(eb, off + 8)  let chh = wlU32(eb, off + 12)
                    if cw > 0 && chh > 0 && (cw != W || chh != H) {
                        W = cw  H = chh
                        if splitMode == 0 {
                            p0_cols = (W - padX * 2) / 8  p0_rows = (H - padY * 2) / 16
                            if p0_cols < 4 { p0_cols = 4 }  if p0_rows < 2 { p0_rows = 2 }
                            ptySetSize(p0_m, p0_rows, p0_cols)
                            p0_gb = bufNew(5 * p0_cols * p0_rows)  p0_ab = bufNew(p0_cols * p0_rows)  p0_bb = bufNew(p0_cols * p0_rows)  p0_ub = bufNew(p0_cols * p0_rows)
                            gridBlank(p0_gb, p0_ab, p0_bb, p0_ub, p0_cols, p0_rows)  p0_meta = gridInitMeta()
                            cols = p0_cols  rows = p0_rows  m = p0_m  gb = p0_gb  ab = p0_ab  bb = p0_bb  ub = p0_ub  meta = p0_meta
                        } else { if splitMode == 1 {
                            let p0w = ((W - padX * 2) * splitRatio / 100) / 8
                            let p1w = ((W - padX * 2) - (p0w * 8) - 2) / 8
                            if p0w < 10 { p0w = 10 }  if p1w < 10 { p1w = 10 }
                            p0_cols = p0w  p0_rows = (H - padY * 2) / 16  p1_cols = p1w  p1_rows = p0_rows
                            ptySetSize(p0_m, p0_rows, p0_cols)  ptySetSize(p1_m, p1_rows, p1_cols)
                            p0_gb = bufNew(5 * p0_cols * p0_rows)  p0_ab = bufNew(p0_cols * p0_rows)  p0_bb = bufNew(p0_cols * p0_rows)  p0_ub = bufNew(p0_cols * p0_rows)
                            p1_gb = bufNew(5 * p1_cols * p1_rows)  p1_ab = bufNew(p1_cols * p1_rows)  p1_bb = bufNew(p1_cols * p1_rows)  p1_ub = bufNew(p1_cols * p1_rows)
                            gridBlank(p0_gb, p0_ab, p0_bb, p0_ub, p0_cols, p0_rows)  p0_meta = gridInitMeta()
                            gridBlank(p1_gb, p1_ab, p1_bb, p1_ub, p1_cols, p1_rows)  p1_meta = gridInitMeta()
                        } else {
                            let p0h = ((H - padY * 2) * splitRatio / 100) / 16
                            let p1h = ((H - padY * 2) - (p0h * 16) - 2) / 16
                            if p0h < 4 { p0h = 4 }  if p1h < 4 { p1h = 4 }
                            p0_cols = (W - padX * 2) / 8  p0_rows = p0h  p1_cols = p0_cols  p1_rows = p1h
                            ptySetSize(p0_m, p0_rows, p0_cols)  ptySetSize(p1_m, p1_rows, p1_cols)
                            p0_gb = bufNew(5 * p0_cols * p0_rows)  p0_ab = bufNew(p0_cols * p0_rows)  p0_bb = bufNew(p0_cols * p0_rows)  p0_ub = bufNew(p0_cols * p0_rows)
                            p1_gb = bufNew(5 * p1_cols * p1_rows)  p1_ab = bufNew(p1_cols * p1_rows)  p1_bb = bufNew(p1_cols * p1_rows)  p1_ub = bufNew(p1_cols * p1_rows)
                            gridBlank(p0_gb, p0_ab, p0_bb, p0_ub, p0_cols, p0_rows)  p0_meta = gridInitMeta()
                            gridBlank(p1_gb, p1_ab, p1_bb, p1_ub, p1_cols, p1_rows)  p1_meta = gridInitMeta()
                        } }
                        hasSel = 0  selecting = 0
                        dirty = 1
                    }
                }
                if obj == TOP && op == 1 {                    // xdg_toplevel.close
                    if confirmClose == 1 && closeArmed == 0 {
                        closeArmed = 1
                        wlSetTitle(fd, TOP, "Close again to confirm - " + winTitle)
                        wlCommit(fd, SURF)
                    } else { running = 0 }
                }
                if obj == 1 && op == 0 { running = 0 }      // wl_display.error
                if obj == KB && op == 4 {                    // wl_keyboard.modifiers (authoritative)
                    let mods = wlU32(eb, off + 12)           // mods_depressed bitmask
                    shift = 0  if bitAnd(mods, 1) != 0 { shift = 1 }   // bit0 = shift
                    ctrl = 0   if bitAnd(mods, 4) != 0 { ctrl = 1 }    // bit2 = ctrl
                    alt = 0    if bitAnd(mods, 8) != 0 { alt = 1 }     // bit3 = mod1 (Alt/Meta)
                }
                if obj == KB && op == 3 {                    // wl_keyboard.key
                    let state = wlU32(eb, off + 20)
                    let kc = wlKeyToKc(wlU32(eb, off + 16))
                    if state == 1 {
                        if mouseHideTyping == 1 { mouseHidden = 1 }
                        let handled = 0
                        let hadSel = hasSel
                        let sSR = selSR  let sSC = selSC  let sER = selER  let sEC = selEC
                        // sync active pane into working vars
                        if activePane == 0 {
                            m = p0_m  meta = p0_meta  scrollback = p0_scrollback  scrollOff = p0_scrollOff  inputLine = p0_inputLine
                            gb = p0_gb  ab = p0_ab  bb = p0_bb  ub = p0_ub  cols = p0_cols  rows = p0_rows  title = p0_title
                        } else {
                            m = p1_m  meta = p1_meta  scrollback = p1_scrollback  scrollOff = p1_scrollOff  inputLine = p1_inputLine
                            gb = p1_gb  ab = p1_ab  bb = p1_bb  ub = p1_ub  cols = p1_cols  rows = p1_rows  title = p1_title
                        }
                        let am = m  let aMeta = meta
                        if closeArmed == 1 { closeArmed = 0  wlSetTitle(fd, TOP, winTitle)  wlCommit(fd, SURF) }

                        // Overlay mode (command palette / history search)
                        if overlayMode != 0 {
                            if kc == 9 { overlayMode = 0  overlayQuery = ""  dirty = 1  handled = 1 } // Esc
                            else { if kc == 36 { // Enter
                                let filtered = kOverlayFilter(overlayItems, overlayQuery)
                                let nF = lineCount(filtered)
                                if overlaySel < 0 { overlaySel = 0 }
                                if overlaySel < nF {
                                    let pick = getLine(filtered, overlaySel)
                                    if pick != "" {
                                        if overlayMode == 2 {
                                            if pick == "reload config" { conf = confLoadMerged()  dirty = 1 }
                                            if pick == "clear scrollback" { scrollback = ""  scrollOff = 0  dirty = 1 }
                                            if pick == "new window" { exec("stem-wl >/dev/null 2>&1 &") }
                                            if pick == "show history" {
                                                overlayItems = kHistoryLoad(histFilePath, histMaxEntries)
                                                overlayQuery = ""  overlaySel = 0  overlayMode = 1  dirty = 1
                                                handled = 1
                                            }
                                            if pick == "doctor" { exec("notify-send -a stem 'STEM doctor' 'Run: stemctl doctor' >/dev/null 2>&1 &") }
                                            if pick == "split right" { if paneCount == 1 { splitMode = 1  paneCount = 2  activePane = 1  let p0w = ((W - padX * 2) * splitRatio / 100) / 8; let p1w = ((W - padX * 2) - (p0w * 8) - 2) / 8; if p0w < 10 { p0w = 10 }  if p1w < 10 { p1w = 10 }; p0_cols = p0w  p0_rows = (H - padY * 2) / 16; p1_cols = p1w  p1_rows = p0_rows; p0_gb = bufNew(5 * p0_cols * p0_rows)  p0_ab = bufNew(p0_cols * p0_rows)  p0_bb = bufNew(p0_cols * p0_rows)  p0_ub = bufNew(p0_cols * p0_rows); gridBlank(p0_gb, p0_ab, p0_bb, p0_ub, p0_cols, p0_rows)  p0_meta = gridInitMeta(); ptySetSize(p0_m, p0_rows, p0_cols); let sp = kSpawnPane(shell, term, workDir, loginShell, shellIntegration, confPathVal); let spc = indexOf(sp, ","); p1_m = toInt(substring(sp, 0, spc))  p1_pid = toInt(substring(sp, spc + 1, len(sp))); p1_gb = bufNew(5 * p1_cols * p1_rows)  p1_ab = bufNew(p1_cols * p1_rows)  p1_bb = bufNew(p1_cols * p1_rows)  p1_ub = bufNew(p1_cols * p1_rows); gridBlank(p1_gb, p1_ab, p1_bb, p1_ub, p1_cols, p1_rows)  p1_meta = gridInitMeta(); p1_scrollback = ""  p1_scrollOff = 0  p1_pending = ""  p1_quiet = 0  p1_title = "stem"; ptySetSize(p1_m, p1_rows, p1_cols); dirty = 1 } }
                                            if pick == "split down" { if paneCount == 1 { splitMode = 2  paneCount = 2  activePane = 1  let p0h = ((H - padY * 2) * splitRatio / 100) / 16; let p1h = ((H - padY * 2) - (p0h * 16) - 2) / 16; if p0h < 4 { p0h = 4 }  if p1h < 4 { p1h = 4 }; p0_cols = (W - padX * 2) / 8  p0_rows = p0h; p1_cols = p0_cols  p1_rows = p1h; p0_gb = bufNew(5 * p0_cols * p0_rows)  p0_ab = bufNew(p0_cols * p0_rows)  p0_bb = bufNew(p0_cols * p0_rows)  p0_ub = bufNew(p0_cols * p0_rows); gridBlank(p0_gb, p0_ab, p0_bb, p0_ub, p0_cols, p0_rows)  p0_meta = gridInitMeta(); ptySetSize(p0_m, p0_rows, p0_cols); let sp = kSpawnPane(shell, term, workDir, loginShell, shellIntegration, confPathVal); let spc = indexOf(sp, ","); p1_m = toInt(substring(sp, 0, spc))  p1_pid = toInt(substring(sp, spc + 1, len(sp))); p1_gb = bufNew(5 * p1_cols * p1_rows)  p1_ab = bufNew(p1_cols * p1_rows)  p1_bb = bufNew(p1_cols * p1_rows)  p1_ub = bufNew(p1_cols * p1_rows); gridBlank(p1_gb, p1_ab, p1_bb, p1_ub, p1_cols, p1_rows)  p1_meta = gridInitMeta(); p1_scrollback = ""  p1_scrollOff = 0  p1_pending = ""  p1_quiet = 0  p1_title = "stem"; ptySetSize(p1_m, p1_rows, p1_cols); dirty = 1 } }
                                            if pick == "focus next pane" { if paneCount > 1 { activePane = 1 - activePane  dirty = 1 } }
                                            if pick == "close pane" { if paneCount > 1 { if activePane == 1 { fdClose(p1_m)  p1_m = 0 - 1  paneCount = 1  splitMode = 0  activePane = 0 } else { fdClose(p0_m); p0_m = p1_m  p0_pid = p1_pid  p0_gb = p1_gb  p0_ab = p1_ab  p0_bb = p1_bb  p0_ub = p1_ub  p0_meta = p1_meta; p0_cols = p1_cols  p0_rows = p1_rows  p0_scrollback = p1_scrollback  p0_scrollOff = p1_scrollOff  p0_pending = p1_pending  p0_quiet = p1_quiet; p0_kicked = p1_kicked  p0_kickIn = p1_kickIn  p0_kickArmed = p1_kickArmed  p0_title = p1_title  p0_inputLine = p1_inputLine; p1_m = 0 - 1  paneCount = 1  splitMode = 0  activePane = 0 }; p0_cols = (W - padX * 2) / 8  p0_rows = (H - padY * 2) / 16; p0_gb = bufNew(5 * p0_cols * p0_rows)  p0_ab = bufNew(p0_cols * p0_rows)  p0_bb = bufNew(p0_cols * p0_rows)  p0_ub = bufNew(p0_cols * p0_rows); gridBlank(p0_gb, p0_ab, p0_bb, p0_ub, p0_cols, p0_rows)  p0_meta = gridInitMeta(); ptySetSize(p0_m, p0_rows, p0_cols); dirty = 1 } else { running = 0 } }
                                            if pick == "swap panes" { if paneCount > 1 { let tm = p0_m  p0_m = p1_m  p1_m = tm; let tp = p0_pid  p0_pid = p1_pid  p1_pid = tp; let tg = p0_gb  p0_gb = p1_gb  p1_gb = tg; let ta = p0_ab  p0_ab = p1_ab  p1_ab = ta; let tb = p0_bb  p0_bb = p1_bb  p1_bb = tb; let tu = p0_ub  p0_ub = p1_ub  p1_ub = tu; let tmeta = p0_meta  p0_meta = p1_meta  p1_meta = tmeta; let tsb = p0_scrollback  p0_scrollback = p1_scrollback  p1_scrollback = tsb; let tso = p0_scrollOff  p0_scrollOff = p1_scrollOff  p1_scrollOff = tso; let tpd = p0_pending  p0_pending = p1_pending  p1_pending = tpd; let tt = p0_title  p0_title = p1_title  p1_title = tt; dirty = 1 } }
                                            if pick == "quit" { running = 0 }
                                            if overlayMode == 2 { overlayMode = 0  overlayQuery = ""  dirty = 1 }
                                        } else {
                                            fdWrite(m, pick, len(pick))
                                            overlayMode = 0  overlayQuery = ""  dirty = 1
                                        }
                                    } else { overlayMode = 0  overlayQuery = ""  dirty = 1 }
                                } else { overlayMode = 0  overlayQuery = ""  dirty = 1 }
                                handled = 1
                            } else { if kc == 111 { overlaySel = overlaySel - 1  if overlaySel < 0 { overlaySel = 0 }  dirty = 1  handled = 1 } // Up
                            else { if kc == 116 { overlaySel = overlaySel + 1  dirty = 1  handled = 1 } // Down
                            else { if kc == 22 { // Backspace
                                let ql = len(overlayQuery)
                                if ql > 0 { overlayQuery = substring(overlayQuery, 0, ql - 1) }
                                overlaySel = 0  dirty = 1  handled = 1
                            } else {
                                let ch = kCharOf(kc, shift)
                                if ch != "" && ctrl == 0 && alt == 0 {
                                    overlayQuery = overlayQuery + ch
                                    overlaySel = 0  dirty = 1  handled = 1
                                } else { handled = 1 }
                            } } } } }
                        }

                        // Configurable keybinds (checked before default PTY forwarding).
                        if handled == 0 && kBindAction(conf, "reload_config", kc, shift, ctrl, alt) == 1 {
                            let conf2 = confLoadMerged()
                            if conf2 != "" {
                                conf = conf2
                                bg = hexColor(confGetAny(conf, "background", "bg", ""), bg)
                                fg = hexColor(confGetAny(conf, "foreground", "fg", ""), fg)
                                curColor = hexColor(confGet(conf, "cursor_color", ""), curColor)
                                let cs2 = confGet(conf, "cursor_style", curStyleS)
                                curStyleS = cs2  curStyle = 0
                                if curStyleS == "bar" { curStyle = 1 }
                                if curStyleS == "underline" { curStyle = 2 }
                                bellMode = confGet(conf, "bell", bellMode)
                                copyOnSelect = confGetBool(conf, "copy_on_select", copyOnSelect)
                                scrollMult = confGetIntAny(conf, "scroll_multiplier", "mouse_scroll_multiplier", scrollMult)
                                if scrollMult < 1 { scrollMult = 1 }
                                sbCap = confGetIntAny(conf, "scrollback", "scrollback_lines", sbCap)
                                pluginsEnabled = confGetBool(conf, "plugins_enabled", pluginsEnabled)
                                pluginDir = confGet(conf, "plugin_dir", pluginDir)
                                pluginEventFormat = confGet(conf, "plugin_event_format", pluginEventFormat)
                                histOn = confGetBool(conf, "command_history", histOn)
                                histFilePath = confGet(conf, "history_file", histFilePath)
                                histMaxEntries = confGetInt(conf, "history_max_entries", histMaxEntries)
                                dirty = 1
                            }
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "copy", kc, shift, ctrl, alt) == 1 {
                            if hadSel == 1 && scrollOff == 0 {
                                let seltext = kSelText(gb, cols, rows, sSR, sSC, sER, sEC)
                                if len(seltext) > 0 {
                                    writeFile("/tmp/.stem_sel", seltext)
                                    exec("wl-copy < /tmp/.stem_sel 2>/dev/null")
                                    exec("wl-copy --primary < /tmp/.stem_sel 2>/dev/null")
                                }
                            }
                            handled = 1
                        }

                        if hasSel == 1 { hasSel = 0  dirty = 1 }     // typing clears the selection
                        if handled == 0 && kBindAction(conf, "paste", kc, shift, ctrl, alt) == 1 {
                            let clip = exec("wl-paste -n 2>/dev/null")
                            kSendPaste(am, clip, aMeta)
                            if scrollOff != 0 { scrollOff = 0 }
                            dirty = 1  handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "clear_scrollback", kc, shift, ctrl, alt) == 1 {
                            scrollback = ""  scrollOff = 0  dirty = 1  handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "scroll_page_up", kc, shift, ctrl, alt) == 1 {
                            scrollOff = scrollOff + rows - 2
                            let maxOff = toInt(lineCount(scrollback))
                            if scrollOff > maxOff { scrollOff = maxOff }
                            dirty = 1  handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "scroll_page_down", kc, shift, ctrl, alt) == 1 {
                            scrollOff = scrollOff - (rows - 2)
                            if scrollOff < 0 { scrollOff = 0 }
                            dirty = 1  handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "scroll_top", kc, shift, ctrl, alt) == 1 {
                            scrollOff = toInt(lineCount(scrollback))  dirty = 1  handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "scroll_bottom", kc, shift, ctrl, alt) == 1 {
                            scrollOff = 0  dirty = 1  handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "jump_to_prompt", kc, shift, ctrl, alt) == 1 {
                            scrollOff = 0  dirty = 1  handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "command_history", kc, shift, ctrl, alt) == 1 {
                            overlayItems = kHistoryLoad(histFilePath, histMaxEntries)
                            overlayQuery = ""
                            overlaySel = 0
                            overlayMode = 1
                            dirty = 1
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "command_palette", kc, shift, ctrl, alt) == 1 {
                            overlayItems = "reload config" + fromCharCode(10) + "clear scrollback" + fromCharCode(10) + "new window" + fromCharCode(10) + "split right" + fromCharCode(10) + "split down" + fromCharCode(10) + "focus next pane" + fromCharCode(10) + "close pane" + fromCharCode(10) + "swap panes" + fromCharCode(10) + "show history" + fromCharCode(10) + "doctor" + fromCharCode(10) + "quit"
                            overlayQuery = ""
                            overlaySel = 0
                            overlayMode = 2
                            dirty = 1
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "new_window", kc, shift, ctrl, alt) == 1 {
                            exec("stem-wl >/dev/null 2>&1 &")
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "split_right", kc, shift, ctrl, alt) == 1 {
                            if paneCount == 1 {
                                splitMode = 1  paneCount = 2  activePane = 1
                                let p0w = ((W - padX * 2) * splitRatio / 100) / 8
                                let p1w = ((W - padX * 2) - (p0w * 8) - 2) / 8
                                if p0w < 10 { p0w = 10 }  if p1w < 10 { p1w = 10 }
                                p0_cols = p0w  p0_rows = (H - padY * 2) / 16
                                p1_cols = p1w  p1_rows = p0_rows
                                p0_gb = bufNew(5 * p0_cols * p0_rows)  p0_ab = bufNew(p0_cols * p0_rows)  p0_bb = bufNew(p0_cols * p0_rows)  p0_ub = bufNew(p0_cols * p0_rows)
                                gridBlank(p0_gb, p0_ab, p0_bb, p0_ub, p0_cols, p0_rows)  p0_meta = gridInitMeta()  p0_scrollback = ""  p0_scrollOff = 0
                                ptySetSize(p0_m, p0_rows, p0_cols)
                                let sp = kSpawnPane(shell, term, workDir, loginShell, shellIntegration, confPathVal)
                                let spc = indexOf(sp, ",")
                                p1_m = toInt(substring(sp, 0, spc))  p1_pid = toInt(substring(sp, spc + 1, len(sp)))
                                p1_gb = bufNew(5 * p1_cols * p1_rows)  p1_ab = bufNew(p1_cols * p1_rows)  p1_bb = bufNew(p1_cols * p1_rows)  p1_ub = bufNew(p1_cols * p1_rows)
                                gridBlank(p1_gb, p1_ab, p1_bb, p1_ub, p1_cols, p1_rows)  p1_meta = gridInitMeta()  p1_scrollback = ""  p1_scrollOff = 0  p1_pending = ""  p1_quiet = 0  p1_title = "stem"
                                ptySetSize(p1_m, p1_rows, p1_cols)
                                dirty = 1
                            }
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "split_down", kc, shift, ctrl, alt) == 1 {
                            if paneCount == 1 {
                                splitMode = 2  paneCount = 2  activePane = 1
                                let p0h = ((H - padY * 2) * splitRatio / 100) / 16
                                let p1h = ((H - padY * 2) - (p0h * 16) - 2) / 16
                                if p0h < 4 { p0h = 4 }  if p1h < 4 { p1h = 4 }
                                p0_cols = (W - padX * 2) / 8  p0_rows = p0h
                                p1_cols = p0_cols  p1_rows = p1h
                                p0_gb = bufNew(5 * p0_cols * p0_rows)  p0_ab = bufNew(p0_cols * p0_rows)  p0_bb = bufNew(p0_cols * p0_rows)  p0_ub = bufNew(p0_cols * p0_rows)
                                gridBlank(p0_gb, p0_ab, p0_bb, p0_ub, p0_cols, p0_rows)  p0_meta = gridInitMeta()  p0_scrollback = ""  p0_scrollOff = 0
                                ptySetSize(p0_m, p0_rows, p0_cols)
                                let sp = kSpawnPane(shell, term, workDir, loginShell, shellIntegration, confPathVal)
                                let spc = indexOf(sp, ",")
                                p1_m = toInt(substring(sp, 0, spc))  p1_pid = toInt(substring(sp, spc + 1, len(sp)))
                                p1_gb = bufNew(5 * p1_cols * p1_rows)  p1_ab = bufNew(p1_cols * p1_rows)  p1_bb = bufNew(p1_cols * p1_rows)  p1_ub = bufNew(p1_cols * p1_rows)
                                gridBlank(p1_gb, p1_ab, p1_bb, p1_ub, p1_cols, p1_rows)  p1_meta = gridInitMeta()  p1_scrollback = ""  p1_scrollOff = 0  p1_pending = ""  p1_quiet = 0  p1_title = "stem"
                                ptySetSize(p1_m, p1_rows, p1_cols)
                                dirty = 1
                            }
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "focus_next_pane", kc, shift, ctrl, alt) == 1 {
                            if paneCount > 1 { activePane = 1 - activePane  dirty = 1 }
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "close_pane", kc, shift, ctrl, alt) == 1 {
                            if paneCount > 1 {
                                if activePane == 1 {
                                    fdClose(p1_m)  p1_m = 0 - 1  paneCount = 1  splitMode = 0  activePane = 0
                                } else {
                                    // close pane 0, promote pane 1 to pane 0
                                    fdClose(p0_m)
                                    p0_m = p1_m  p0_pid = p1_pid  p0_gb = p1_gb  p0_ab = p1_ab  p0_bb = p1_bb  p0_ub = p1_ub  p0_meta = p1_meta
                                    p0_cols = p1_cols  p0_rows = p1_rows  p0_scrollback = p1_scrollback  p0_scrollOff = p1_scrollOff  p0_pending = p1_pending  p0_quiet = p1_quiet
                                    p0_kicked = p1_kicked  p0_kickIn = p1_kickIn  p0_kickArmed = p1_kickArmed  p0_title = p1_title  p0_inputLine = p1_inputLine
                                    p1_m = 0 - 1  paneCount = 1  splitMode = 0  activePane = 0
                                }
                                // restore full size
                                p0_cols = (W - padX * 2) / 8  p0_rows = (H - padY * 2) / 16
                                p0_gb = bufNew(5 * p0_cols * p0_rows)  p0_ab = bufNew(p0_cols * p0_rows)  p0_bb = bufNew(p0_cols * p0_rows)  p0_ub = bufNew(p0_cols * p0_rows)
                                gridBlank(p0_gb, p0_ab, p0_bb, p0_ub, p0_cols, p0_rows)  p0_meta = gridInitMeta()
                                ptySetSize(p0_m, p0_rows, p0_cols)
                                dirty = 1
                            } else {
                                running = 0
                            }
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "split_equalize", kc, shift, ctrl, alt) == 1 {
                            if paneCount > 1 { splitRatio = 50  dirty = 1
                                if splitMode == 1 {
                                    let p0w = ((W - padX * 2) * splitRatio / 100) / 8
                                    let p1w = ((W - padX * 2) - (p0w * 8) - 2) / 8
                                    if p0w < 10 { p0w = 10 }  if p1w < 10 { p1w = 10 }
                                    p0_cols = p0w  p0_rows = (H - padY * 2) / 16  p1_cols = p1w  p1_rows = p0_rows
                                } else {
                                    let p0h = ((H - padY * 2) * splitRatio / 100) / 16
                                    let p1h = ((H - padY * 2) - (p0h * 16) - 2) / 16
                                    if p0h < 4 { p0h = 4 }  if p1h < 4 { p1h = 4 }
                                    p0_cols = (W - padX * 2) / 8  p0_rows = p0h  p1_cols = p0_cols  p1_rows = p1h
                                }
                                ptySetSize(p0_m, p0_rows, p0_cols)  ptySetSize(p1_m, p1_rows, p1_cols)
                            }
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "split_grow", kc, shift, ctrl, alt) == 1 {
                            if paneCount > 1 { splitRatio = splitRatio + 5  if splitRatio > 80 { splitRatio = 80 }  dirty = 1
                                if splitMode == 1 { let p0w = ((W - padX * 2) * splitRatio / 100) / 8; let p1w = ((W - padX * 2) - (p0w * 8) - 2) / 8; if p0w < 10 { p0w = 10 }  if p1w < 10 { p1w = 10 }  p0_cols = p0w  p1_cols = p1w  p0_rows = (H - padY * 2) / 16  p1_rows = p0_rows }
                                else { let p0h = ((H - padY * 2) * splitRatio / 100) / 16; let p1h = ((H - padY * 2) - (p0h * 16) - 2) / 16; if p0h < 4 { p0h = 4 }  if p1h < 4 { p1h = 4 }  p0_rows = p0h  p1_rows = p1h  p0_cols = (W - padX * 2) / 8  p1_cols = p0_cols }
                                ptySetSize(p0_m, p0_rows, p0_cols)  ptySetSize(p1_m, p1_rows, p1_cols)
                            }
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "split_shrink", kc, shift, ctrl, alt) == 1 {
                            if paneCount > 1 { splitRatio = splitRatio - 5  if splitRatio < 20 { splitRatio = 20 }  dirty = 1
                                if splitMode == 1 { let p0w = ((W - padX * 2) * splitRatio / 100) / 8; let p1w = ((W - padX * 2) - (p0w * 8) - 2) / 8; if p0w < 10 { p0w = 10 }  if p1w < 10 { p1w = 10 }  p0_cols = p0w  p1_cols = p1w  p0_rows = (H - padY * 2) / 16  p1_rows = p0_rows }
                                else { let p0h = ((H - padY * 2) * splitRatio / 100) / 16; let p1h = ((H - padY * 2) - (p0h * 16) - 2) / 16; if p0h < 4 { p0h = 4 }  if p1h < 4 { p1h = 4 }  p0_rows = p0h  p1_rows = p1h  p0_cols = (W - padX * 2) / 8  p1_cols = p0_cols }
                                ptySetSize(p0_m, p0_rows, p0_cols)  ptySetSize(p1_m, p1_rows, p1_cols)
                            }
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "swap_panes", kc, shift, ctrl, alt) == 1 {
                            if paneCount > 1 {
                                let tm = p0_m  p0_m = p1_m  p1_m = tm
                                let tp = p0_pid  p0_pid = p1_pid  p1_pid = tp
                                let tg = p0_gb  p0_gb = p1_gb  p1_gb = tg
                                let ta = p0_ab  p0_ab = p1_ab  p1_ab = ta
                                let tb = p0_bb  p0_bb = p1_bb  p1_bb = tb
                                let tu = p0_ub  p0_ub = p1_ub  p1_ub = tu
                                let tmeta = p0_meta  p0_meta = p1_meta  p1_meta = tmeta
                                let tsb = p0_scrollback  p0_scrollback = p1_scrollback  p1_scrollback = tsb
                                let tso = p0_scrollOff  p0_scrollOff = p1_scrollOff  p1_scrollOff = tso
                                let tpd = p0_pending  p0_pending = p1_pending  p1_pending = tpd
                                let tt = p0_title  p0_title = p1_title  p1_title = tt
                                dirty = 1
                            }
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "toggle_fullscreen", kc, shift, ctrl, alt) == 1 {
                            kHyprctl(hyprlandIpc, "dispatch fullscreen 0")
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "open_config", kc, shift, ctrl, alt) == 1 {
                            exec("xdg-open " + confPathVal + " >/dev/null 2>&1 &")
                            handled = 1
                        }
                        if handled == 0 && kBindAction(conf, "close_window", kc, shift, ctrl, alt) == 1 {
                            if confirmClose == 1 && closeArmed == 0 {
                                closeArmed = 1
                                wlSetTitle(fd, TOP, "Close again to confirm - " + winTitle)
                                wlCommit(fd, SURF)
                            } else { running = 0 }
                            handled = 1
                        }

                        // Built-in fallback: Shift+PageUp/Down scrollback (also works if not rebound).
                        if handled == 0 && shift == 1 && kc == 112 {
                            scrollOff = scrollOff + rows - 2
                            let maxOff = toInt(lineCount(scrollback))
                            if scrollOff > maxOff { scrollOff = maxOff }
                            dirty = 1  handled = 1
                        }
                        if handled == 0 && shift == 1 && kc == 117 {
                            scrollOff = scrollOff - (rows - 2)
                            if scrollOff < 0 { scrollOff = 0 }
                            dirty = 1  handled = 1
                        }

                        // paste fallback: Ctrl-Shift-V or Shift-Insert
                        if handled == 0 {
                            let isPaste = 0
                            if ctrl == 1 && shift == 1 && kc == 55 { isPaste = 1 }
                            if shift == 1 && kc == 118 { isPaste = 1 }
                            if isPaste == 1 {
                                let clip = exec("wl-paste -n 2>/dev/null")
                                kSendPaste(am, clip, aMeta)
                                if scrollOff != 0 { scrollOff = 0  dirty = 1 }
                                handled = 1
                            }
                        }

                        if handled == 0 {
                            if scrollOff != 0 { scrollOff = 0  dirty = 1 }   // any other key jumps back to live
                            let bytes = kKeyBytes(kc, shift, ctrl, alt, kittyKeyboard)
                            if bytes != "" {
                                fdWrite(am, bytes, len(bytes))
                                // Naive command history capture (terminal-side, best-effort).
                                if histOn == 1 && ctrl == 0 && alt == 0 {
                                    if kc == 36 {              // Enter
                                        if trim(inputLine) != "" {
                                            kHistoryAppend(histFilePath, histOn, inputLine)
                                            let pOut = kPluginEmit(pluginDir, pluginsEnabled, "command", inputLine, confPathVal, pluginEventFormat)
                                            let pAct = kPluginApplyCommands(pOut, m, confPathVal)
                                            if pAct == "reload" { conf = confLoadMerged() }
                                        }
                                        inputLine = ""
                                    } else { if kc == 22 {     // Backspace
                                        let il = len(inputLine)
                                        if il > 0 { inputLine = substring(inputLine, 0, il - 1) }
                                    } else {
                                        let ch = kCharOf(kc, shift)
                                        if ch != "" && len(ch) == 1 { inputLine = inputLine + ch }
                                    } } }
                                }
                                if histOn == 1 && ctrl == 1 {
                                    if kc == 54 || kc == 30 { inputLine = "" } // Ctrl+C / Ctrl+U
                                }
                            }
                        }
                    }
                    // sync working vars back to active pane
                    if activePane == 0 {
                        p0_m = m  p0_meta = meta  p0_scrollback = scrollback  p0_scrollOff = scrollOff  p0_inputLine = inputLine
                        p0_gb = gb  p0_ab = ab  p0_bb = bb  p0_ub = ub  p0_cols = cols  p0_rows = rows  p0_title = title
                    } else {
                        p1_m = m  p1_meta = meta  p1_scrollback = scrollback  p1_scrollOff = scrollOff  p1_inputLine = inputLine
                        p1_gb = gb  p1_ab = ab  p1_bb = bb  p1_ub = ub  p1_cols = cols  p1_rows = rows  p1_title = title
                    }
                }
                if obj == PTR && op == 2 {                   // wl_pointer.motion -> track cell
                    mouseHidden = 0
                    let pxm = toInt(wlU32(eb, off + 12)) / 256   // wl_fixed -> px
                    let pym = toInt(wlU32(eb, off + 16)) / 256
                    let mPane = activePane
                    let mOx = 0  let mOy = 0  let mCols = p0_cols  let mRows = p0_rows  let mMeta = p0_meta  let mM = p0_m
                    if splitMode == 1 {
                        let p0pw2 = (W * splitRatio / 100)
                        if pxm >= p0pw2 { mPane = 1  mOx = p0pw2  mCols = p1_cols  mRows = p1_rows  mMeta = p1_meta  mM = p1_m }
                        else { mPane = 0  mOx = 0  mCols = p0_cols  mRows = p0_rows  mMeta = p0_meta  mM = p0_m }
                    } else { if splitMode == 2 {
                        let p0ph2 = (H * splitRatio / 100)
                        if pym >= p0ph2 { mPane = 1  mOy = p0ph2  mCols = p1_cols  mRows = p1_rows  mMeta = p1_meta  mM = p1_m }
                        else { mPane = 0  mOy = 0  mCols = p0_cols  mRows = p0_rows  mMeta = p0_meta  mM = p0_m }
                    } else { mPane = 0  mOx = 0  mOy = 0  mCols = p0_cols  mRows = p0_rows  mMeta = p0_meta  mM = p0_m } }
                    mousePane = mPane
                    let nC = (pxm - mOx - 4) / 8   if nC < 0 { nC = 0 }  if nC >= mCols { nC = mCols - 1 }
                    let nR = (pym - mOy - 4) / 16  if nR < 0 { nR = 0 }  if nR >= mRows { nR = mRows - 1 }
                    let moved = 0  if nC != ptrC || nR != ptrR { moved = 1 }
                    ptrC = nC  ptrR = nR
                    if selecting == 1 && mPane == activePane { selER = ptrR  selEC = ptrC  hasSel = 1  dirty = 1 }
                    if moved == 1 && heldBtn >= 0 && shift == 0 {
                        let amM = gridMouseM(mMeta)
                        let amcM = indexOf(amM, ",")
                        if toInt(substring(amM, 0, amcM)) >= 2 {
                            let seq = kMouseSeq(toInt(substring(amM, amcM + 1, len(amM))), heldBtn + 32, ptrC, ptrR, 1)
                            fdWrite(mM, seq, len(seq))
                        }
                    }
                }
                if obj == PTR && op == 3 {                   // wl_pointer.button
                    let btn = wlU32(eb, off + 16)            // BTN_LEFT = 272
                    let bstate = wlU32(eb, off + 20)         // 1 = pressed
                    if bstate == 1 && mousePane != activePane && paneCount > 1 { activePane = mousePane  dirty = 1 }
                    // sync active pane for mouse ops
                    if activePane == 0 { m = p0_m  meta = p0_meta  gb = p0_gb  ab = p0_ab  bb = p0_bb  ub = p0_ub  cols = p0_cols  rows = p0_rows  scrollback = p0_scrollback  scrollOff = p0_scrollOff }
                    else { m = p1_m  meta = p1_meta  gb = p1_gb  ab = p1_ab  bb = p1_bb  ub = p1_ub  cols = p1_cols  rows = p1_rows  scrollback = p1_scrollback  scrollOff = p1_scrollOff }
                    let amB = gridMouseM(meta)
                    let amcB = indexOf(amB, ",")
                    let mlevelB = toInt(substring(amB, 0, amcB))
                    let msgrB = toInt(substring(amB, amcB + 1, len(amB)))
                    if mlevelB > 0 && shift == 0 {
                        let mbtn = 0 - 1
                        if btn == 272 { mbtn = 0 }  if btn == 274 { mbtn = 1 }  if btn == 273 { mbtn = 2 }
                        if mbtn >= 0 {
                            let seq = kMouseSeq(msgrB, mbtn, ptrC, ptrR, bstate)
                            fdWrite(m, seq, len(seq))
                            if bstate == 1 { heldBtn = mbtn } else { heldBtn = 0 - 1 }
                        }
                    } else { if btn == 272 {
                        if bstate == 1 {
                            selecting = 1  hasSel = 0
                            selSR = ptrR  selSC = ptrC  selER = ptrR  selEC = ptrC
                            dirty = 1
                        } else {
                            selecting = 0
                            if hasSel == 1 && scrollOff == 0 {
                                let seltext = kSelText(gb, cols, rows, selSR, selSC, selER, selEC)
                                if len(seltext) > 0 {
                                    writeFile("/tmp/.stem_sel", seltext)
                                    exec("wl-copy --primary < /tmp/.stem_sel 2>/dev/null")
                                    if copyOnSelect == 1 { exec("wl-copy < /tmp/.stem_sel 2>/dev/null") }
                                }
                            }
                        }
                    }
                    if btn == 274 && bstate == 1 {
                        let clip = exec("wl-paste --primary -n 2>/dev/null")
                        kSendPaste(m, clip, meta)
                        if scrollOff != 0 { scrollOff = 0  dirty = 1 }
                    }
                    }
                    // sync back mouse-affected pane state
                    if activePane == 0 { p0_m = m  p0_meta = meta  p0_scrollback = scrollback  p0_scrollOff = scrollOff }
                    else { p1_m = m  p1_meta = meta  p1_scrollback = scrollback  p1_scrollOff = scrollOff }
                }
                if obj == PTR && op == 4 {                   // wl_pointer.axis (scroll wheel)
                    let ax = wlU32(eb, off + 12)             // 0 = vertical
                    if ax == 0 {
                        if activePane == 0 { m = p0_m  meta = p0_meta  scrollback = p0_scrollback  scrollOff = p0_scrollOff }
                        else { m = p1_m  meta = p1_meta  scrollback = p1_scrollback  scrollOff = p1_scrollOff }
                        let msb = toInt(bufGetByte(eb, off + 19))   // sign byte (negative = up)
                        let amW = gridMouseM(meta)
                        let amcW = indexOf(amW, ",")
                        let mlevelW = toInt(substring(amW, 0, amcW))
                        let msgrW = toInt(substring(amW, amcW + 1, len(amW)))
                        if mlevelW > 0 && shift == 0 {
                            let wb = 65  if msb >= 128 { wb = 64 }
                            let seq = kMouseSeq(msgrW, wb, ptrC, ptrR, 1)
                            fdWrite(m, seq, len(seq))
                        } else {
                            if msb >= 128 {
                                scrollOff = scrollOff + scrollMult
                                let maxOff = toInt(lineCount(scrollback))
                                if scrollOff > maxOff { scrollOff = maxOff }
                                dirty = 1
                            } else {
                                scrollOff = scrollOff - scrollMult
                                if scrollOff < 0 { scrollOff = 0 }
                                dirty = 1
                            }
                        }
                        if activePane == 0 { p0_scrollback = scrollback  p0_scrollOff = scrollOff }
                        else { p1_scrollback = scrollback  p1_scrollOff = scrollOff }
                    }
                }
                off = off + s
            }
        // 2) drain pty output for all panes
        // PTY output for all panes
        let pi = 0
        while pi < paneCount {
            if pi == 0 { m = p0_m  meta = p0_meta  gb = p0_gb  ab = p0_ab  bb = p0_bb  ub = p0_ub  cols = p0_cols  rows = p0_rows  scrollback = p0_scrollback  scrollOff = p0_scrollOff  pending = p0_pending  quiet = p0_quiet  kicked = p0_kicked  kickIn = p0_kickIn  kickArmed = p0_kickArmed  title = p0_title }
            else { m = p1_m  meta = p1_meta  gb = p1_gb  ab = p1_ab  bb = p1_bb  ub = p1_ub  cols = p1_cols  rows = p1_rows  scrollback = p1_scrollback  scrollOff = p1_scrollOff  pending = p1_pending  quiet = p1_quiet  kicked = p1_kicked  kickIn = p1_kickIn  kickArmed = p1_kickArmed  title = p1_title }
            let out = fdRead(m, 16384)
            if len(out) > 0 {
                outBytesTotal = outBytesTotal + len(out)
                if kickArmed == 1 { kickIn = 30 }
                let chunk = pending + out
                let nt = oscTitle(chunk, title)
                if nt != title && nt != "" { title = nt  if pi == activePane { wlSetTitle(fd, TOP, title)  wlCommit(fd, SURF) } }
                if osc133Enabled == 1 {
                    let cwd7 = osc7Cwd(chunk)
                    if cwd7 != "" && cwd7 != currentCwd {
                        currentCwd = cwd7
                        kPluginEmit(pluginDir, pluginsEnabled, "cwd", currentCwd, confPathVal, pluginEventFormat)
                        if confGetBool(conf, "title_includes_cwd", 1) == 1 && pi == activePane {
                            winTitle = "STEM - " + currentCwd
                            wlSetTitle(fd, TOP, winTitle)  wlCommit(fd, SURF)
                        }
                    }
                    let ev133 = osc133Event(chunk)
                    if ev133 != "" {
                        promptMark = ev133
                        if len(ev133) >= 1 && substring(ev133, 0, 1) == "C" { cmdStartSeen = 1 }
                        if len(ev133) >= 1 && substring(ev133, 0, 1) == "D" {
                            cmdStartSeen = 0
                            kPluginEmit(pluginDir, pluginsEnabled, "prompt", ev133 + fromCharCode(10) + currentCwd, confPathVal, pluginEventFormat)
                        }
                    }
                }
                let cut = gridSafeLen(chunk)
                if cut > 0 {
                    let fed = substring(chunk, 0, cut)
                    let dm = dec2026Mode(fed)
                    if dm == 1 { syncOutput = 1 }
                    if syncOutput == 1 && dm != -1 {
                        syncBuf = syncBuf + fed
                    } else {
                        if dm == -1 { fed = syncBuf + fed  syncBuf = ""  syncOutput = 0 }
                        let oc = oscApply(fed, pal)
                        osc52Apply(fed, osc52Policy)
                        let oci = indexOf(oc, ",")
                        let ocFg = toInt(substring(oc, 0, oci))
                        let ocR = substring(oc, oci + 1, len(oc))
                        let ocj = indexOf(ocR, ",")
                        let ocBg = toInt(substring(ocR, 0, ocj))
                        let ocCur = toInt(substring(ocR, ocj + 1, len(ocR)))
                        if ocFg >= 0 { fg = ocFg }
                        if ocBg >= 0 { bg = ocBg }
                        if ocCur >= 0 { curColor = ocCur }
                        meta = gridFeedB(gb, ab, bb, ub, meta, fed, cols, rows)
                        let rep = termReplies(fed, meta, cols, rows)
                        if len(rep) > 0 { fdWrite(m, rep, len(rep)) }
                        if gridBellM(meta) == 1 {
                            if bellMode == "visual" { bell = 1 }
                            let pBell = kPluginEmit(pluginDir, pluginsEnabled, "bell", "", confPathVal, pluginEventFormat)
                            let pBellAct = kPluginApplyCommands(pBell, m, confPathVal)
                            if pBellAct == "reload" { conf = confLoadMerged() }
                        }
                        let sc = gridScrolledM(meta)
                        if len(sc) > 0 {
                            scrollback = scrollback + sc
                            let cap = sbCap * 200
                            if len(scrollback) > cap { scrollback = substring(scrollback, len(scrollback) - cap, len(scrollback)) }
                        }
                        dirty = 1
                    }
                }
                pending = substring(chunk, cut, len(chunk))
                quiet = 0
            } else {
                quiet = quiet + 1
                if quiet >= 2 && len(pending) > 0 { meta = gridFeedB(gb, ab, bb, ub, meta, pending, cols, rows)  pending = ""  dirty = 1 }
            }
            // debounced startup kick per pane
            if kickArmed == 1 && kickIn > 0 {
                kickIn = kickIn - 1
                if kickIn == 0 { fdWrite(m, fromCharCode(12), 1)  kicked = 1  kickArmed = 0  dirty = 1 }
            }
            if pi == 0 { p0_m = m  p0_meta = meta  p0_gb = gb  p0_ab = ab  p0_bb = bb  p0_ub = ub  p0_cols = cols  p0_rows = rows  p0_scrollback = scrollback  p0_scrollOff = scrollOff  p0_pending = pending  p0_quiet = quiet  p0_kicked = kicked  p0_kickIn = kickIn  p0_kickArmed = kickArmed  p0_title = title }
            else { p1_m = m  p1_meta = meta  p1_gb = gb  p1_ab = ab  p1_bb = bb  p1_ub = ub  p1_cols = cols  p1_rows = rows  p1_scrollback = scrollback  p1_scrollOff = scrollOff  p1_pending = pending  p1_quiet = quiet  p1_kicked = kicked  p1_kickIn = kickIn  p1_kickArmed = kickArmed  p1_title = title }
            pi = pi + 1
        }

        // 3) shell exited?
        if waitChild(childPid) != 0 { running = 0 }

        // 3b) control plane (stemctl / plugins / automation)
        ctlCtr = ctlCtr + 1
        if ctlCtr >= 20 {
            ctlCtr = 0
            let ctlAct = kControlPoll(controlFile, controlEnabled, m, confPathVal)
            if ctlAct == "reload" { conf = confLoadMerged()  dirty = 1 }
            if ctlAct == "quit" { running = 0 }
            if len(ctlAct) > 10 && substring(ctlAct, 0, 10) == "set_title:" {
                winTitle = trim(substring(ctlAct, 10, len(ctlAct)))
                wlSetTitle(fd, TOP, winTitle)  wlCommit(fd, SURF)
            }
        }

        // 4) present. Reuse ONE shared memfd/mmap/pool across frames (mmapShared
        // has no munmap, so a per-frame mapping leaked ~MBs/frame -> OOM crash).
        // Reallocate only when the window grows beyond the current allocation.
        if dirty == 1 && configured == 1 && running == 1 {
            let stride = W * 4
            let sz = stride * H
            if sz > fbSz {
                if fbPool != 0 {
                    if prevBuf != 0 { wlBufferDestroy(fd, prevBuf)  prevBuf = 0 }
                    wlPoolDestroy(fd, fbPool)  sockClose(fbMem)   // old mapping leaks (rare: only on grow)
                }
                fbMem = memfdCreate(sz)
                fbPx = mmapShared(fbMem, sz)
                fbPool = nextId  nextId = nextId + 1
                wlCreatePool(fd, SHM, fbPool, fbMem, sz)
                fbSz = sz
            }
            let px = fbPx
            fbFillRect(px, W, 0, 0, W, H, bg)
            if splitMode == 0 {
                let aGB = p0_gb  let aAB = p0_ab  let aBB = p0_bb  let aUB = p0_ub  let aMeta = p0_meta
                let aCols = p0_cols  let aRows = p0_rows  let aSB = p0_scrollback  let aSO = p0_scrollOff
                if aSO > 0 { kDrawScrollback(px, W, H, font, aSB, aGB, aCols, aRows, aSO, bg, fg, padX, padY, 0, 0, W, H) }
                else { kDrawScreen(px, W, H, font, aGB, aAB, aBB, aUB, aMeta, aCols, aRows, bg, fg, bell, curColor, curStyle, hasSel, selSR, selSC, selER, selEC, pal, padX, padY, 0, 0, W, H, selBg, selFg, linkColor) }
            } else {
                // split: compute pane rects
                let p0ox = 0  let p0oy = 0  let p0pw = W  let p0ph = H
                let p1ox = 0  let p1oy = 0  let p1pw = W  let p1ph = H
                if splitMode == 1 {
                    p0pw = (W * splitRatio / 100)
                    p1ox = p0pw  p1pw = W - p0pw
                } else {
                    p0ph = (H * splitRatio / 100)
                    p1oy = p0ph  p1ph = H - p0ph
                }
                // pane 0
                let p0bell = 0  if activePane == 0 { p0bell = bell }
                if p0_scrollOff > 0 { kDrawScrollback(px, W, H, font, p0_scrollback, p0_gb, p0_cols, p0_rows, p0_scrollOff, bg, fg, 4, 4, p0ox, p0oy, p0pw, p0ph) }
                else { kDrawScreen(px, W, H, font, p0_gb, p0_ab, p0_bb, p0_ub, p0_meta, p0_cols, p0_rows, bg, fg, p0bell, curColor, curStyle, hasSel, selSR, selSC, selER, selEC, pal, 4, 4, p0ox, p0oy, p0pw, p0ph, selBg, selFg, linkColor) }
                // pane 1
                let p1bell = 0  if activePane == 1 { p1bell = bell }
                if p1_scrollOff > 0 { kDrawScrollback(px, W, H, font, p1_scrollback, p1_gb, p1_cols, p1_rows, p1_scrollOff, bg, fg, 4, 4, p1ox, p1oy, p1pw, p1ph) }
                else { kDrawScreen(px, W, H, font, p1_gb, p1_ab, p1_bb, p1_ub, p1_meta, p1_cols, p1_rows, bg, fg, p1bell, curColor, curStyle, 0, 0, 0, 0, pal, 4, 4, p1ox, p1oy, p1pw, p1ph, selBg, selFg, linkColor) }
                // divider
                if splitMode == 1 { fbFillRect(px, W, p1ox - 1, 0, 2, H, 9134987) }
                else { fbFillRect(px, W, 0, p1oy - 1, W, 2, 9134987) }
            }
            frameCount = frameCount + 1
            perfCtr = perfCtr + 1
            if debugOverlay == 1 || fpsOverlay == 1 {
                let dbg = "stem " + cols + "x" + rows + " f=" + frameCount + " out=" + outBytesTotal + " cwd=" + currentCwd
                fbFillRect(px, W, padX, H - padY - 18, W - padX * 2, 18, 1973790)
                fbDrawText(px, W, H, font, padX + 4, H - padY - 16, dbg, 16777215)
            }
            if perfLog == 1 && perfCtr >= 120 {
                perfCtr = 0
                kPerfLog(perfLog, perfLogFile, "frame=" + frameCount + " out=" + outBytesTotal + " cols=" + cols + " rows=" + rows)
            }
            if overlayMode != 0 {
                let ovTitle = "History"
                if overlayMode == 2 { ovTitle = "Command Palette" }
                let filtered = kOverlayFilter(overlayItems, overlayQuery)
                kOverlayDraw(px, W, H, font, ovTitle, filtered, overlayQuery, overlaySel)
            }
            let didFlash = bell  bell = 0
            let buf = nextId  nextId = nextId + 1
            wlPoolCreateBuffer(fd, fbPool, buf, 0, W, H, stride, 1)
            wlSurfaceAttach(fd, SURF, buf, 0, 0)
            wlDamage(fd, SURF, 0, 0, W, H)
            wlCommit(fd, SURF)
            if prevBuf != 0 { wlBufferDestroy(fd, prevBuf) }   // free previous frame's lightweight wl_buffer
            prevBuf = buf
            dirty = 0
            if didFlash == 1 { dirty = 1 }   // bell flashed this frame -> redraw normal next frame
        }
        // adaptive poll: fdRead allocates its buffer every call (no GC), so spinning
        // at 8ms while idle is a slow leak. Back off to ~40ms after the shell goes
        // quiet; snap back to 8ms the moment data flows (keeps typing responsive).
        let frameUs = 1000000 / maxFps
        if frameUs < 4000 { frameUs = 4000 }
        if quiet > 3 { sleepUs(0, 40000) } else { sleepUs(0, frameUs) }
    }
    // clean shutdown: closing the pty master hangs up the shell (SIGHUP); drop
    // the wayland connection so the surface is destroyed (no orphan window).
    if restoreSession == 1 {
        let sp = kExpandPath(sessionFile)
        confEnsureParent(sp)
        let sdat = "cwd=" + currentCwd + fromCharCode(10) + "cols=" + cols + fromCharCode(10) + "rows=" + rows + fromCharCode(10) + "title=" + winTitle + fromCharCode(10)
        sdat = sdat + "split_mode=" + splitMode + fromCharCode(10) + "split_ratio=" + splitRatio + fromCharCode(10) + "active_pane=" + activePane + fromCharCode(10)
        writeFile(sp, sdat)
    }
    if p1_m >= 0 { fdClose(p1_m) }
    fdClose(p0_m)
    sockClose(fd)
    emit 0
}
