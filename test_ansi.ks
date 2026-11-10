import "./ansi.k"
just run {
  let esc = fromCharCode(27)
  let bel = fromCharCode(7)
  print("[CSI] [" + stripAnsi(esc + "[31m" + "RED" + esc + "[0m" + " plain") + "]")
  print("[OSC] [" + stripAnsi(esc + "]0;mytitle" + bel + "after") + "]")
  print("[mix] [" + stripAnsi("a" + fromCharCode(10) + "b" + esc + "[2J" + "c") + "]")
  print("[bare][" + stripAnsi("just text, no escapes") + "]")
}
