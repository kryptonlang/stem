// stem_core.k — embeddable STEM terminal core API.
//
// Stable, library-style interface over term.k. No GUI, no PTY ownership.
// Callers feed bytes/events in and pull snapshots/rendered state out.
// Updates happen via explicit calls (no web/network API required).

module stem_core

import "./term.k"

func coreNew(cols, rows) {
    let gb = bufNew(5 * cols * rows)
    let ab = bufNew(cols * rows)
    let bb = bufNew(cols * rows)
    let ub = bufNew(cols * rows)
    gridBlank(gb, ab, bb, ub, cols, rows)
    let meta = gridInitMeta()
    emit "ok"
}

func coreInitMeta() { emit gridInitMeta() }
func coreBlank(gb, ab, bb, ub, cols, rows) { emit gridBlank(gb, ab, bb, ub, cols, rows) }
func coreFeed(gb, ab, bb, ub, meta, s, cols, rows) { emit gridFeedB(gb, ab, bb, ub, meta, s, cols, rows) }
func coreRender(gb, ab, bb, cols, rows) { emit gridRenderB(gb, ab, bb, cols, rows) }
func corePlain(gb, cols, rows) { emit gridPlainB(gb, cols, rows) }
func coreCursor(meta) { emit gridCursorM(meta) }
func coreMouse(meta) { emit gridMouseM(meta) }
func corePaste(meta) { emit gridPasteM(meta) }
func coreBell(meta) { emit gridBellM(meta) }
func coreScrolled(meta) { emit gridScrolledM(meta) }
func coreShape(meta) { emit gridCshapeM(meta) }
func coreAlt(meta) { emit gridAltM(meta) }
func coreFocus(meta) { emit gridFocusM(meta) }
func coreSync2026(meta) { emit gridSync2026M(meta) }
func coreOsc133(meta) { emit gridOsc133M(meta) }
func coreLink(meta) { emit gridCurLinkM(meta) }
func coreKittyKb(meta) { emit gridKittyKbM(meta) }
func coreTitle(s, old) { emit oscTitle(s, old) }
func coreSafeLen(s) { emit gridSafeLen(s) }
func coreStripSgr(s) { emit gridStripSgr(s) }
func coreFind(scrollback, gridText, rows, query, matchIdx) { emit gridFind(scrollback, gridText, rows, query, matchIdx) }
func coreScrollView(scrollback, gridText, rows, scrollOff) { emit gridScrollView(scrollback, gridText, rows, scrollOff) }

// --- Session/embedding helpers (library-style, no web API) ---
// coreCreate: allocate plane buffers and meta. Returns "gb,ab,bb,ub,meta,cols,rows" as a packed object string.
// Callers keep buffers as opaque handles in their runtime; this API is the stable call surface.
func coreCreate(cols, rows) {
    let gb = bufNew(5 * cols * rows)
    let ab = bufNew(cols * rows)
    let bb = bufNew(cols * rows)
    let ub = bufNew(cols * rows)
    gridBlank(gb, ab, bb, ub, cols, rows)
    let meta = gridInitMeta()
    emit "" + gb + "|" + ab + "|" + bb + "|" + ub + "|" + meta + "|" + cols + "|" + rows
}

func coreResize(cols, rows) {
    let gb = bufNew(5 * cols * rows)
    let ab = bufNew(cols * rows)
    let bb = bufNew(cols * rows)
    let ub = bufNew(cols * rows)
    gridBlank(gb, ab, bb, ub, cols, rows)
    let meta = gridInitMeta()
    emit "" + gb + "|" + ab + "|" + bb + "|" + ub + "|" + meta + "|" + cols + "|" + rows
}

func coreFeedBytes(gb, ab, bb, ub, meta, bytes, cols, rows) {
    emit gridFeedB(gb, ab, bb, ub, meta, bytes, cols, rows)
}

func coreSnapshot(gb, ab, bb, cols, rows) {
    emit gridRenderB(gb, ab, bb, cols, rows)
}

func corePlainText(gb, cols, rows) {
    emit gridPlainB(gb, cols, rows)
}

func corePollEvents(meta) {
    // Returns compact event string: bell,scrolled,alt,focus,paste,mouse,sync2026,osc133,link
    let tail = meta
    let sohp = indexOf(tail, fromCharCode(1))
    if sohp >= 0 { tail = substring(tail, 0, sohp) }
    // fields by index
    emit "" + gridBellM(meta) + "," + len(gridScrolledM(meta)) + "," + gridAltM(meta) + "," + gridFocusM(meta) + "," + gridPasteM(meta) + "," + gridMouseM(meta) + "," + gridSync2026M(meta) + "," + gridOsc133M(meta) + "," + gridCurLinkM(meta)
}