// config.k — stem configuration.
//
// Easy, Linux-first config for STEM. Supports:
//   - Plaintext: key = value, # comments, blank lines
//   - JSON: flat object in stem.json/config.json (most complex supported format)
//
// Locations (first found unless STEM_CONF is set):
//   $STEM_CONF
//   $XDG_CONFIG_HOME/stem/stem.conf | stem.json | config | config.json
//   ~/.config/stem/stem.conf | stem.json | config | config.json
//
// A missing file or key falls back to defaults. Values support:
//   bool:   true/false, yes/no, on/off, 1/0
//   int:    decimal integer
//   float:  decimal number (parsed as string; use confGet for exact text)
//   color:  #RRGGBB, 0xRRGGBB, RRGGBB
//   path:   ~ and $ENV are expanded by confExpandPath
//
// Pure Krypton — no syscalls beyond readFile/writeFile/environ/exec.
module config

// ── paths ────────────────────────────────────────────────────────────────────

func confDir() {
    let xdg = environ("XDG_CONFIG_HOME")
    if xdg != "" { emit xdg + "/stem" }
    emit environ("HOME") + "/.config/stem"
}

// Active config path: $STEM_CONF wins, else <confDir>/stem.conf.
func confPath() {
    let p = environ("STEM_CONF")
    if p != "" { emit p }
    let c = confDir() + "/stem.conf"
    if readFile(c) != "" { emit c }
    let j = confDir() + "/stem.json"
    if readFile(j) != "" { emit j }
    let c2 = confDir() + "/config"
    if readFile(c2) != "" { emit c2 }
    let j2 = confDir() + "/config.json"
    if readFile(j2) != "" { emit j2 }
    emit confDir() + "/stem.conf"
}

func _confIsJsonPath(p) {
    let lp = confLower(p)
    let n = len(lp)
    if n >= 5 && substring(lp, n - 5, n) == ".json" { emit 1 }
    emit 0
}

func _confIsJsonText(txt) {
    let t = trim(txt)
    if t == "" { emit 0 }
    let first = substring(t, 0, 1)
    if first == "{" || first == "[" { emit 1 }
    emit 0
}

func _jsonSkipWs(s, i) {
    let n = len(s)
    while i < n {
        let c = substring(s, i, i + 1)
        if c == " " || c == fromCharCode(10) || c == fromCharCode(13) || c == fromCharCode(9) { i = i + 1 }
        else { emit i }
    }
    emit i
}

func _jsonParseString(s, i) {
    // i at opening quote; returns value + fromCharCode(1) + nextIndex
    let n = len(s)
    i = i + 1
    let out = ""
    while i < n {
        let ch = substring(s, i, i + 1)
        if ch == "\"" {
            emit out + fromCharCode(1) + (i + 1)
        }
        if ch == "\\" {
            if i + 1 < n {
                let esc = substring(s, i + 1, i + 2)
                if esc == "n" { out = out + "\\n" }
                else { if esc == "r" { out = out + "" }
                else { if esc == "t" { out = out + " " }
                else { out = out + esc } } }
                i = i + 2
            } else { i = i + 1 }
        } else {
            out = out + ch
            i = i + 1
        }
    }
    emit out + fromCharCode(1) + i
}

func _jsonParsePrimitive(s, i) {
    let n = len(s)
    let start = i
    while i < n {
        let ch = substring(s, i, i + 1)
        if ch == "," || ch == "}" || ch == "]" || ch == " " || ch == fromCharCode(10) || ch == fromCharCode(13) || ch == fromCharCode(9) {
            emit trim(substring(s, start, i)) + fromCharCode(1) + i
        }
        i = i + 1
    }
    emit trim(substring(s, start, i)) + fromCharCode(1) + i
}

func _jsonParseValue(s, i) {
    // returns valueString + fromCharCode(1) + nextIndex
    i = _jsonSkipWs(s, i)
    let n = len(s)
    if i >= n { emit "" + fromCharCode(1) + i }
    let ch = substring(s, i, i + 1)
    if ch == "\"" { emit _jsonParseString(s, i) }
    if ch == "{" {
        // flatten nested object as JSON-ish string for now; callers can use include/theme_file/profile_file
        let depth = 0
        let start = i
        while i < n {
            let c = substring(s, i, i + 1)
            if c == "\"" {
                let pr = _jsonParseString(s, i)
                let sep = indexOf(pr, fromCharCode(1))
                i = toInt(substring(pr, sep + 1, len(pr)))
            } else {
                if c == "{" { depth = depth + 1 }
                if c == "}" { depth = depth - 1  i = i + 1  if depth == 0 { emit trim(substring(s, start, i)) + fromCharCode(1) + i } }
                else { i = i + 1 }
            }
        }
        emit trim(substring(s, start, i)) + fromCharCode(1) + i
    }
    if ch == "[" {
        let depth = 0
        let start = i
        let items = ""
        i = i + 1
        while i < n {
            i = _jsonSkipWs(s, i)
            if i >= n { emit items + fromCharCode(1) + i }
            let c2 = substring(s, i, i + 1)
            if c2 == "]" { emit items + fromCharCode(1) + (i + 1) }
            let vr = _jsonParseValue(s, i)
            let sep2 = indexOf(vr, fromCharCode(1))
            let v = substring(vr, 0, sep2)
            i = toInt(substring(vr, sep2 + 1, len(vr)))
            if items == "" { items = v } else { items = items + ", " + v }
            i = _jsonSkipWs(s, i)
            if i < n && substring(s, i, i + 1) == "," { i = i + 1 }
        }
        emit items + fromCharCode(1) + i
    }
    emit _jsonParsePrimitive(s, i)
}

func _confJsonFlatten(prefix, s, i) {
    // Parses object at i, returns "lines\0nextIndex"
    let n = len(s)
    i = _jsonSkipWs(s, i)
    if i >= n || substring(s, i, i + 1) != "{" { emit "" + fromCharCode(1) + i }
    i = i + 1
    let out = ""
    while i < n {
        i = _jsonSkipWs(s, i)
        if i >= n { emit out + fromCharCode(1) + i }
        let ch = substring(s, i, i + 1)
        if ch == "}" { emit out + fromCharCode(1) + (i + 1) }
        if ch == "," { i = i + 1 }
        else {
            if ch == "\"" {
                let kr = _jsonParseString(s, i)
                let ksep = indexOf(kr, fromCharCode(1))
                let key = substring(kr, 0, ksep)
                i = toInt(substring(kr, ksep + 1, len(kr)))
                i = _jsonSkipWs(s, i)
                if i < n && substring(s, i, i + 1) == ":" { i = i + 1 }
                i = _jsonSkipWs(s, i)
                let fullKey = key
                if prefix != "" { fullKey = prefix + "." + key }
                if i < n && substring(s, i, i + 1) == "{" {
                    let fr = _confJsonFlatten(fullKey, s, i)
                    let fsep = indexOf(fr, fromCharCode(1))
                    out = out + substring(fr, 0, fsep)
                    i = toInt(substring(fr, fsep + 1, len(fr)))
                } else {
                    let vr = _jsonParseValue(s, i)
                    let vsep = indexOf(vr, fromCharCode(1))
                    let val = substring(vr, 0, vsep)
                    i = toInt(substring(vr, vsep + 1, len(vr)))
                    let lv = confLower(trim(val))
                    if lv == "null" { val = "" }
                    out = out + fullKey + " = " + val + fromCharCode(10)
                    // Also emit bare leaf key for simple one-level nesting (e.g. window.cols -> cols)
                    if prefix != "" && indexOf(prefix, ".") < 0 {
                        out = out + key + " = " + val + fromCharCode(10)
                    }
                }
            } else { i = i + 1 }
        }
    }
    emit out + fromCharCode(1) + i
}

func confJsonToConf(txt) {
    let s = trim(txt)
    if s == "" { emit "" }
    let r = _confJsonFlatten("", s, 0)
    let sep = indexOf(r, fromCharCode(1))
    emit substring(r, 0, sep)
}

func confNormalize(txt, path) {
    if _confIsJsonPath(path) || _confIsJsonText(txt) {
        let c = confJsonToConf(txt)
        if c != "" { emit c }
    }
    emit txt
}

// Raw config text ("" if the file does not exist). Supports key=value conf and JSON.
func confLoad() {
    let p = confPath()
    let txt = readFile(p)
    if txt != "" { emit confNormalize(txt, p) }
    let alt1 = confDir() + "/stem.json"
    txt = readFile(alt1)
    if txt != "" { emit confNormalize(txt, alt1) }
    let alt2 = confDir() + "/config"
    txt = readFile(alt2)
    if txt != "" { emit confNormalize(txt, alt2) }
    let alt3 = confDir() + "/config.json"
    txt = readFile(alt3)
    if txt != "" { emit confNormalize(txt, alt3) }
    emit ""
}

// ── path helpers ─────────────────────────────────────────────────────────────

func confExpandPath(p) {
    if p == "" { emit "" }
    let home = environ("HOME")
    if p == "~" { emit home }
    if len(p) >= 2 && substring(p, 0, 2) == "~/" { emit home + substring(p, 1, len(p)) }
    // Expand leading $VAR (simple single-var prefix, common for $HOME/...).
    if substring(p, 0, 1) == "$" {
        let slash = indexOf(p, "/")
        let vname = p
        let rest = ""
        if slash > 0 {
            vname = substring(p, 1, slash)
            rest = substring(p, slash, len(p))
        } else {
            vname = substring(p, 1, len(p))
        }
        let vval = environ(vname)
        if vval != "" { emit vval + rest }
    }
    emit p
}

func confEnsureDir(path) {
    if path == "" { emit 0 }
    exec("mkdir -p \"" + path + "\" >/dev/null 2>&1")
    emit 0
}

func confEnsureParent(path) {
    if path == "" { emit 0 }
    // Strip trailing filename component.
    let i = len(path) - 1
    while i >= 0 {
        let ch = substring(path, i, i + 1)
        if ch == "/" {
            if i > 0 { confEnsureDir(substring(path, 0, i)) }
            emit 0
        }
        i = i - 1
    }
    emit 0
}

// ── parsing ──────────────────────────────────────────────────────────────────

func _confStripInlineComment(v) {
    // Strip inline # comment, but preserve # inside a leading quote-less hex color
    // only when the whole trimmed value looks like #RRGGBB. Otherwise strip at #.
    let t = trim(v)
    if len(t) > 0 && substring(t, 0, 1) == "#" {
        // Value itself starts with # (color) — keep it, but strip a later " # ...".
        let rest = substring(t, 1, len(t))
        let h = indexOf(rest, "#")
        if h >= 0 { emit trim(substring(t, 0, h + 1)) }
        emit t
    }
    let h = indexOf(t, "#")
    if h >= 0 { emit trim(substring(t, 0, h)) }
    emit t
}

// confGet(conf, key, def): trimmed value for `key`, or `def` if absent.
func confGet(conf, key, def) {
    let n = lineCount(conf)
    let i = 0
    while i < n {
        let line = trim(getLine(conf, i))
        if len(line) > 0 {
            let first = substring(line, 0, 1)
            if first != "#" && first != ";" {
                let eq = indexOf(line, "=")
                if eq <= 0 {
                    eq = indexOf(line, ":")  // tolerate key: value for ease
                }
                if eq > 0 {
                    let k = trim(substring(line, 0, eq))
                    if k == key {
                        let raw = substring(line, eq + 1, len(line))
                        emit _confStripInlineComment(raw)
                    }
                }
            }
        }
        i = i + 1
    }
    emit def
}

func confHas(conf, key) {
    let sentinel = fromCharCode(1) + "STEM_NO" + fromCharCode(1)
    let v = confGet(conf, key, sentinel)
    if v == sentinel { emit 0 }
    emit 1
}

// confGetInt(conf, key, def): integer value, or `def` if absent/blank.
func confGetInt(conf, key, def) {
    let v = confGet(conf, key, "")
    if v == "" { emit def }
    emit toInt(v)
}

func confLower(s) {
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

func confGetBool(conf, key, def) {
    let v = confLower(trim(confGet(conf, key, "")))
    if v == "" { emit def }
    if v == "1" || v == "true" || v == "yes" || v == "on" { emit 1 }
    if v == "0" || v == "false" || v == "no" || v == "off" { emit 0 }
    emit def
}

// confGetFloat/confGetNum: returns the raw string for the caller to parse as
// needed (Krypton float handling varies by backend).
func confGetFloat(conf, key, def) {
    let v = confGet(conf, key, "")
    if v == "" { emit def }
    emit v
}

// First key wins among aliases - lets us migrate names without breaking configs.
func confGetAny(conf, k1, k2, def) {
    if confHas(conf, k1) == 1 { emit confGet(conf, k1, def) }
    emit confGet(conf, k2, def)
}
func confGetIntAny(conf, k1, k2, def) {
    if confHas(conf, k1) == 1 { emit confGetInt(conf, k1, def) }
    emit confGetInt(conf, k2, def)
}
func confGetBoolAny(conf, k1, k2, def) {
    if confHas(conf, k1) == 1 { emit confGetBool(conf, k1, def) }
    emit confGetBool(conf, k2, def)
}

// ── includes / profiles / themes ─────────────────────────────────────────────
// Simple one-level include support: lines like `include = path` or `theme_file = path`
// are resolved by callers. confLoadMerged() merges include files in order.
func confLoadMerged() {
    let base = confLoad()
    let out = base
    let n = lineCount(base)
    let i = 0
    while i < n {
        let line = trim(getLine(base, i))
        if len(line) > 8 && substring(line, 0, 8) == "include " {
            let p = trim(substring(line, 8, len(line)))
            p = confExpandPath(p)
            let inc = confNormalize(readFile(p), p)
            if inc != "" { out = out + fromCharCode(10) + inc }
        } else {
            let eq = indexOf(line, "=")
            if eq > 0 {
                let k = trim(substring(line, 0, eq))
                if k == "include" || k == "include_file" || k == "theme_file" || k == "profile_file" {
                    let p = confExpandPath(_confStripInlineComment(substring(line, eq + 1, len(line))))
                    let inc = confNormalize(readFile(p), p)
                    if inc != "" { out = out + fromCharCode(10) + inc }
                }
            }
        }
        i = i + 1
    }
    emit out
}

// Basic validation: returns newline-separated warnings.
func confValidate(conf) {
    if _confIsJsonText(conf) { emit "" }
    let warns = ""
    let n = lineCount(conf)
    let i = 0
    while i < n {
        let line = trim(getLine(conf, i))
        if len(line) > 0 {
            let first = substring(line, 0, 1)
            if first != "#" && first != ";" && first != "{" && first != "}" && first != "[" && first != "]" {
                let eq = indexOf(line, "=")
                let colon = indexOf(line, ":")
                if eq <= 0 && colon <= 0 {
                    warns = warns + "line " + (i + 1) + ": missing '=': " + line + fromCharCode(10)
                }
            }
        }
        i = i + 1
    }
    emit warns
}
