import "./term.k"
just run {
  let esc = fromCharCode(27)
  let nl = fromCharCode(10)
  print("=== plain 'ab' 5x2 ===");                print("[" + renderGrid("ab", 5, 2) + "]")
  print("=== CUP ESC[2;6H 'Hi' (Hi at row1 col5) ==="); print("[" + renderGrid(esc + "[2;6H" + "Hi", 12, 3) + "]")
  print("=== text + newline ===");                print("[" + renderGrid("line1" + nl + "line2", 12, 3) + "]")
  print("=== CR overwrite XXXXX\\rab -> abXXX ==="); print("[" + renderGrid("XXXXX" + fromCharCode(13) + "ab", 10, 1) + "]")
  print("=== cursor up: AB\\nCD ESC[1A Z -> Z over A ==="); print("[" + renderGrid("AB" + nl + "CD" + esc + "[1A" + "Z", 6, 2) + "]")
  print("=== erase ESC[2J wipes ===");            print("[" + renderGrid("junk" + esc + "[2J", 8, 2) + "]")
}
