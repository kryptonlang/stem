// build_linux.ks — build STEM on Linux (x86_64 / aarch64).
//
// Pure-Krypton build path: kcc compiles STEM sources to native ELF binaries.
// No gcc/cmake/clang at user-build time once kcc is bootstrapped.
//
// Usage:
//   kcc -r build_linux.ks            # builds ./stem CLI from run.k
//   kcc -r build_linux.ks --ks       # builds CLI from run.ks
//   kcc -r build_linux.ks --wl       # builds ./stem-wl Wayland/Hyprland frontend
//   kcc -r build_linux.ks --run      # build then run the selected target
//
// kcc resolution: `kcc` on PATH, else the Linux driver seed in $KRYPTON_ROOT
// (default ../krypton).

func has(cmd) { emit trim(exec("command -v " + cmd + " >/dev/null 2>&1 && echo yes || echo no")) }
func isExec(p) { emit trim(exec("test -x \"" + p + "\" && echo yes || echo no")) }

just run {
    // Toolchain resolution, in priority order:
    //   1. an explicit KRYPTON_ROOT checkout's driver — wins over PATH so a stale
    //      brew `kcc` (e.g. 2.0.0) can't shadow a current repo,
    //   2. `kcc` on PATH,
    //   3. a default ../krypton checkout.
    let kcc = ""
    let root = environ("KRYPTON_ROOT")
    if root != "" {
        let seedPath = root + "/bootstrap/kcc_driver_linux_x86_64"
        if isExec(seedPath) == "yes" { kcc = "env KRYPTON_ROOT=\"" + root + "\" \"" + seedPath + "\"" }
    }
    if kcc == "" {
        if has("kcc") == "yes" {
            kcc = "kcc"
        } else {
            let r = "../krypton"
            let seedPath = r + "/bootstrap/kcc_driver_linux_x86_64"
            if isExec(seedPath) != "yes" {
                print("build_linux.ks: no 'kcc' on PATH and no " + seedPath)
                print("  Set KRYPTON_ROOT to your krypton checkout, or install Krypton.")
                emit 1
            }
            kcc = "env KRYPTON_ROOT=\"" + r + "\" \"" + seedPath + "\""
        }
    }

    let src = "run.k"
    let outName = "stem"
    let run = 0
    let i = 0
    while i < argCount() {
        let a = arg(toStr(i))
        if a == "--run" { run = 1 }
        if a == "--ks"  { src = "run.ks" }
        if a == "--wl"  { src = "stem_wl.ks"  outName = "stem-wl" }
        i = i + 1
    }

    print("build_linux.ks: " + src + " -> " + outName)
    let out = exec(kcc + " --native " + src + " -o " + outName + " 2>&1")
    if out != "" { print(out) }
    if isExec(outName) != "yes" {
        print("build_linux.ks: build failed — " + outName + " not produced")
        emit 1
    }
    print("build_linux.ks: built " + outName + " (" + trim(exec("wc -c < " + outName + " | tr -d ' '")) + " bytes)")
    if run == 1 { exec("./" + outName) }
}
