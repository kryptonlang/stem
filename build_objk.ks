// build_objk.ks — build the PURE-KRYPTON stem GUI (objk FFI). No Obj-C source.
//
// Window + custom NSView drawRect grid + keyDown->pty + NSTimer/pump loop are
// all Krypton (stem.ks) on the objk Objective-C FFI. The built app links only
// libobjc + Foundation + AppKit — verify: otool -L dist/stem.app/Contents/MacOS/stem
//
// objk shipped in Krypton 2.4.0, so the installed (released) kcc builds it.
// KRYPTON_ROOT optionally points at a dev checkout
// (compiler/macos_arm64/{kcc-arm64,macho_host} + stdlib/cocoa.k + headers);
// default: sibling ../krypton. Run from the repo root:  kcc -r build_objk.ks
//
// Output layout (default build is unchanged for compatibility):
//   kcc -r build_objk.ks            # dist/stem.app       (classic FFI)
//   kcc -r build_objk.ks --kbi      # dist/kbi/stem.app   (KBI fast ABI)
//   STEMBUILD_KBI=1 kcc -r build_objk.ks   # same as --kbi (backwards compat)
//
// --kbi is EXPERIMENTAL and gates on a startup smoke check: the built binary
// is launched and must survive ~15s (or exit rc=0), otherwise the build
// fails loudly and the broken bundle is removed. STEM_SKIP_SMOKE=1 skips
// the check (not recommended). KBI is macOS-arm64 only.

func isExec(p) { emit trim(exec("test -x \"" + p + "\" && echo yes || echo no")) }
func isFile(p) { emit trim(exec("test -f \"" + p + "\" && echo yes || echo no")) }
func newer(a, b) { emit trim(exec("test \"" + a + "\" -nt \"" + b + "\" && echo yes || echo no")) }
func hasFlag(name) {
    let i = 0
    while i < argCount() {
        if arg(i) == name { emit "1" }
        i += 1
    }
    emit "0"
}

just run {
    let version = trim(readFile("VERSION"))
    if version == "" { version = "0.1.0" }
    let root = environ("KRYPTON_ROOT")
    if root == "" { root = "../krypton" }
    let fe   = root + "/compiler/macos_arm64/kcc-arm64"
    let host = root + "/compiler/macos_arm64/macho_host"
    let backend = root + "/compiler/macos_arm64/macho_arm64_self.k"

    if isFile(root + "/stdlib/cocoa.k") != "yes" {
        print("build_objk.ks: KRYPTON_ROOT='" + root + "' is not a Krypton dev checkout.")
        print("  set KRYPTON_ROOT=/path/to/krypton (needs compiler/macos_arm64 + stdlib + headers)")
        emit 1
    }
    if isExec(fe) != "yes" {
        print("build_objk.ks: missing " + fe)
        emit 1
    }

    // Ensure the macho codegen host is built from the current backend.
    if isExec(host) != "yes" {
        print("==> building macho_host from macho_arm64_self.k")
        exec("kcc --native \"" + backend + "\" -o \"" + host + "\"")
    } else {
        if newer(backend, host) == "yes" {
            print("==> rebuilding macho_host (backend changed)")
            exec("kcc --native \"" + backend + "\" -o \"" + host + "\"")
        }
    }

    print("==> compiling stem.ks (objk, pure Krypton)")
    // KBI (Krypton Binary Interface) fast ABI is opt-in: `--kbi` on the CLI
    // (or STEMBUILD_KBI=1). macOS arm64 only. The two flavors build into
    // separate output directories so they can never clobber each other.
    let kbi = "0"
    if hasFlag("--kbi") == "1" { kbi = "1" }
    if environ("STEMBUILD_KBI") == "1" { kbi = "1" }
    let kbiFlag = ""
    let app = "dist/stem.app"
    let flavor = "default (classic FFI)"
    if kbi == "1" {
        kbiFlag = " --kbi"
        app = "dist/kbi/stem.app"
        flavor = "KBI fast ABI"
        print("==> --kbi: building with KBI fast ABI -> " + app)
    }
    // stem.ks keeps the GUI self-contained for source browsing, while term.k
    // is the canonical, tested VT core. Build with the current term.k so the
    // macOS app cannot drift behind fixes for progress redraws, cursor motion,
    // bounded buffer mutation, or incomplete CSI handling.
    exec("(sed -n '1,5p' stem.ks; sed '/^module stem_term$/d' term.k; sed -n '/^\\/\\/ ── objk GUI/,$p' stem.ks) > /tmp/stem-build.ks")
    exec("env KRYPTON_ROOT=\"" + root + "\" \"" + fe + "\"" + kbiFlag + " /tmp/stem-build.ks > /tmp/stem.kir")
    exec("\"" + host + "\" --ir /tmp/stem.kir /tmp/stem.bin >/dev/null")

    exec("rm -rf \"" + app + "\"")
    exec("mkdir -p \"" + app + "/Contents/MacOS\" \"" + app + "/Contents/Resources\"")
    exec("cp /tmp/stem.bin \"" + app + "/Contents/MacOS/stem\"")
    exec("chmod +x \"" + app + "/Contents/MacOS/stem\"")
    // Keep resource name Finder-safe. Versioned name defeats stale icon cache.
    let iconName = "stem-v0_1_0"
    if isFile("stem.icns") == "yes" { exec("cp stem.icns \"" + app + "/Contents/Resources/" + iconName + ".icns\"") }
    if isFile("stem.conf") == "yes" { exec("cp stem.conf \"" + app + "/Contents/Resources/stem.conf\"") }

    let q = fromCharCode(34)
    let plist = "<?xml version=" + q + "1.0" + q + " encoding=" + q + "UTF-8" + q + "?>\n" +
        "<!DOCTYPE plist PUBLIC " + q + "-//Apple//DTD PLIST 1.0//EN" + q + " " + q + "http://www.apple.com/DTDs/PropertyList-1.0.dtd" + q + ">\n" +
        "<plist version=" + q + "1.0" + q + "><dict>\n" +
        "  <key>CFBundleName</key><string>stem</string>\n" +
        "  <key>CFBundleDisplayName</key><string>stem</string>\n" +
        "  <key>CFBundleExecutable</key><string>stem</string>\n" +
        "  <key>CFBundleIdentifier</key><string>org.krypton-lang.stem</string>\n" +
        "  <key>CFBundleIconFile</key><string>" + iconName + ".icns</string>\n" +
        "  <key>CFBundlePackageType</key><string>APPL</string>\n" +
        "  <key>CFBundleShortVersionString</key><string>" + version + "</string>\n" +
        "  <key>CFBundleVersion</key><string>" + version + "</string>\n" +
        "  <key>LSMinimumSystemVersion</key><string>11.0</string>\n" +
        "  <key>NSHighResolutionCapable</key><true/>\n" +
        "  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>\n" +
        "</dict></plist>\n"
    writeFile(app + "/Contents/Info.plist", plist)

    exec("codesign -s - -f \"" + app + "/Contents/MacOS/stem\" >/dev/null 2>&1")
    exec("codesign -s - -f \"" + app + "\" >/dev/null 2>&1")

    if kbi == "1" && environ("STEM_SKIP_SMOKE") != "1" {
        // KBI is experimental: smoke-check that the binary actually boots.
        // objk apps crash on launch under KBI on this toolchain; shipping
        // one would be a silent trap. Fail the build loudly instead.
        // A wrapper records the app's exit code: if it crashes on startup,
        // the status file appears within seconds carrying the signal rc.
        // If the app is alive after 15s (normal for a GUI app with no user
        // input), the smoke check passes.
        print("==> KBI smoke check: launching the binary (up to 15s)...")
        let smokeLog = "/tmp/stem_kbi_smoke_" + trim(exec("date +%s")) + ".log"
        let statusFile = smokeLog + ".status"
        exec("nohup sh -c '\"" + app + "/Contents/MacOS/stem\" > \"" + smokeLog + "\" 2>&1; echo $? > \"" + statusFile + "\"' > /dev/null 2>&1 &")
        let smokeRc = ""
        let i = 0
        while i < 60 {
            sleepUs(0, 250000)
            if isFile(statusFile) == "yes" {
                smokeRc = trim(readFile(statusFile))
                break
            }
            i += 1
        }
        exec("rm -f \"" + statusFile + "\"")
        if smokeRc == "" {
            exec("pkill -f '" + app + "/Contents/MacOS/stem' || true")
            exec("rm -f \"" + smokeLog + "\"")
            print("==> KBI smoke check passed (app survived 15s)")
        } else if smokeRc == "0" {
            exec("rm -f \"" + smokeLog + "\"")
            print("==> KBI smoke check passed (app exited cleanly)")
        } else {
            print("build_objk.ks: KBI binary crashed on startup (exit rc=" + smokeRc + "). Log:")
            exec("cat \"" + smokeLog + "\"")
            print("")
            print("build_objk.ks: KBI builds are experimental on this toolchain and do not currently boot.")
            print("  The default build (dist/stem.app) is unaffected. Set STEM_SKIP_SMOKE=1 to skip this check (not recommended).")
            exec("rm -rf \"" + app + "\"")
            exec("rm -f \"" + smokeLog + "\"")
            emit 1
        }
    }

    print("==> built " + app + " [" + flavor + "] (pure Krypton, no Obj-C source). Run:  open " + app)
}
