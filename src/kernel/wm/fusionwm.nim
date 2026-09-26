#[
  FusionWM: a basic IceWM-style window manager.

  Runs as a kernel task. It owns the screen: desktop background, an IceWM-like
  taskbar at the bottom (program/task buttons + clock), draggable windows with
  title bars and minimize/maximize/close buttons, and a software mouse cursor.

  Input comes from the PS/2 keyboard and mouse drivers via channels; rendering
  goes directly to the shared framebuffer (con/framebuffer). The text console
  is suspended while the GUI runs; type `exit` in the shell to bring it back.
]#

import std/[algorithm, sequtils, strformat]

import channels
import common/serde
import con/[framebuffer as fb, font]
import drivers/kbd
import drivers/mouse
import sched
import task
import taskmgr
import timer
import wm/geometry
import wm/window

let
  logger = DebugLogger(name: "wm")

const
  ScreenW = 1280
  ScreenH = 960
  TaskbarHeight = 34
  StartBtnWidth = 90
  ClockWidth = 120

  ColDesktop = 0x5677A8'u32     # slate blue desktop
  ColTaskbar = 0xC3CBD6'u32     # IceWM silver taskbar
  ColTaskbarHi = 0xE8EDF2'u32
  ColTaskbarLo = 0x6C7683'u32
  ColText = 0x182028'u32
  ColWhite = 0xFFFFFF'u32

type
  DragKind = enum
    dkNone
    dkMove

  DragState = object
    win: Window
    kind: DragKind
    offsetX, offsetY: int

  WmState = object
    windows: seq[Window]        ## bottom .. top stacking order
    activeWin: Window
    mouseChId: int
    kbdSrcChId: int   ## the keyboard driver's channel (shared with the console)
    mouseX, mouseY: int
    mouseButtons: set[mouse.MouseButton]
    leftWasDown: bool
    drag: DragState
    hoverWidget: Widget
    clockMinutes: int
    bootMinutes: int            ## minute count at WM start (fake wall clock)
    tickCount: int
    shutdownRequested: bool
    consoleTask: Task           ## suspended text console; resumed on exit

var
  st: WmState
  curFont = dina15x7

proc workArea(): Rect =
  Rect(x: 0, y: 0, w: ScreenW, h: ScreenH - TaskbarHeight)

proc taskbarRect(): Rect =
  Rect(x: 0, y: ScreenH - TaskbarHeight, w: ScreenW, h: TaskbarHeight)

proc startButtonRect(): Rect =
  Rect(x: 3, y: ScreenH - TaskbarHeight + 4, w: StartBtnWidth, h: TaskbarHeight - 8)

proc clockRect(): Rect =
  Rect(x: ScreenW - ClockWidth - 4, y: ScreenH - TaskbarHeight + 4, w: ClockWidth, h: TaskbarHeight - 8)

proc taskButtonRect(idx: int): Rect =
  let x = startButtonRect().x + startButtonRect().w + 6 + idx * (150 + 4)
  Rect(x: x, y: ScreenH - TaskbarHeight + 4, w: 150, h: TaskbarHeight - 8)

proc padZero2(n: int): string =
  if n < 10: "0" & $n else: $n

proc clockString(): string =
  let m = (st.bootMinutes + st.clockMinutes) mod (24 * 60)
  result = padZero2(m div 60) & ":" & padZero2(m mod 60)

####################################################################################################
# low-level drawing helpers
####################################################################################################

proc drawBevel(r: Rect, light, dark: uint32) =
  for i in 0 ..< r.w:
    fb.putPixel(r.x + i, r.y, light)
    fb.putPixel(r.x + i, r.bottom - 1, dark)
  for j in 0 ..< r.h:
    fb.putPixel(r.x, r.y + j, light)
    fb.putPixel(r.right - 1, r.y + j, dark)

proc drawFlatButton(r: Rect, label: string, textColor: uint32, pressed, highlighted: bool) =
  let face = if pressed: ColTaskbarLo elif highlighted: ColTaskbarHi else: ColTaskbar
  fb.putRectFilled(r.x, r.y, r.w, r.h, face)
  if pressed:
    drawBevel(r, ColTaskbarLo, ColTaskbarHi)
  else:
    drawBevel(r, ColTaskbarHi, ColTaskbarLo)
  if label.len > 0:
    let tw = label.len * curFont.width
    let tx = r.x + (r.w - tw) div 2
    let ty = r.y + (r.h - curFont.height) div 2
    drawGlyphs(tx, ty, label, textColor)

####################################################################################################
# cursor
####################################################################################################

const
  CursorW = 12
  CursorH = 19
  CursorMask: array[CursorH, uint16] = [
    0b110000000000,
    0b111000000000,
    0b111100000000,
    0b111110000000,
    0b111111000000,
    0b111111100000,
    0b111111110000,
    0b111111111000,
    0b111111111100,
    0b111111111110,
    0b111111111111,
    0b111111111111,
    0b111110000000,
    0b111111100000,
    0b111111111000,
    0b111111111100,
    0b111111111110,
    0b111111111111,
    0b111111111000,
  ]
  CursorColor = 0x101010'u32
  CursorEdge = 0xF0F0F0'u32

var cursorSave: array[CursorH * CursorW, uint32]
var cursorSaved = false

proc saveCursorPixels() =
  cursorSaved = false
  if st.mouseX < 0 or st.mouseY < 0: return
  if st.mouseX + CursorW > ScreenW or st.mouseY + CursorH > ScreenH: return
  for j in 0 ..< CursorH:
    for i in 0 ..< CursorW:
      cursorSave[j * CursorW + i] = fb.getPixel(st.mouseX + i, st.mouseY + j)
  cursorSaved = true

proc restoreCursorPixels() =
  if not cursorSaved: return
  cursorSaved = false
  for j in 0 ..< CursorH:
    for i in 0 ..< CursorW:
      fb.putPixel(st.mouseX + i, st.mouseY + j, cursorSave[j * CursorW + i])

proc drawCursor() =
  for j in 0 ..< CursorH:
    for i in 0 ..< CursorW:
      let inShape = int((CursorMask[j] shr (CursorW - 1 - i)) and 1)
      let neighborIn =
        if i == 0 or j == 0: 0
        else: int((CursorMask[j] shr (CursorW - i)) and 1)
      let x = st.mouseX + i
      let y = st.mouseY + j
      if x < 0 or y < 0 or x >= ScreenW or y >= ScreenH:
        continue
      if inShape == 1:
        fb.putPixel(x, y, CursorColor)
      elif neighborIn == 1:
        fb.putPixel(x, y, CursorEdge)

####################################################################################################
# hit testing
####################################################################################################

proc topmostWindowAt(p: Point): Window =
  for i in countdown(st.windows.high, 0):
    let win = st.windows[i]
    if wfMinimized in win.flags: continue
    if win.rect.contains(p): return win
  nil

proc widgetAt(win: Window, p: Point): Widget =
  for wd in win.widgets:
    if wd.kind == wkButton and wd.rect.contains(p):
      return wd
  nil

####################################################################################################
# compositing / repaint
####################################################################################################

proc raiseWindow(win: Window) =
  let i = st.windows.find(win)
  if i >= 0 and i != st.windows.high:
    st.windows.delete(i)
    st.windows.add(win)
  st.activeWin = win
  for w in st.windows:
    w.active = (w == win)

proc closeWindow(win: Window) =
  logger.info &"closing window {win.id} \"{win.title}\""
  let i = st.windows.find(win)
  if i >= 0:
    st.windows.delete(i)
  if st.activeWin == win:
    st.activeWin = if st.windows.len > 0: st.windows[^1] else: nil
    if st.activeWin != nil:
      st.activeWin.active = true
  if win.onClose != nil:
    win.onClose(win)

proc minimizeWindow(win: Window) =
  win.flags.incl(wfMinimized)
  if st.activeWin == win:
    st.activeWin = nil
    for i in countdown(st.windows.high, 0):
      let w = st.windows[i]
      if wfMinimized notin w.flags:
        st.activeWin = w
        w.active = true
        break

proc toggleMaximize(win: Window) =
  if wfMaximized in win.flags:
    win.flags.excl(wfMaximized)
    win.rect = win.restoreRect
  else:
    win.flags.incl(wfMaximized)
    win.restoreRect = win.rect
    win.rect = Rect(
      x: 0, y: 0,
      w: workArea().w,
      h: workArea().h,
    )
  win.relayout()

proc repaintWindows() =
  for win in st.windows:
    if wfMinimized in win.flags: continue
    win.draw()
    # redraw title bar button labels etc. are part of win.draw(); clipping is
    # handled by bounds checks in putPixel paths of drawGlyphs above

proc drawTaskbar() =
  let tb = taskbarRect()
  fb.putRectFilled(tb.x, tb.y, tb.w, tb.h, ColTaskbar)
  drawBevel(Rect(x: tb.x, y: tb.y, w: tb.w, h: 2), ColTaskbarHi, ColTaskbarLo)

  # "start"-like program menu button
  drawFlatButton(startButtonRect(), "Fusion", ColText,
    pressed = false, highlighted = false)

  # task buttons (IceWM style)
  var idx = 0
  for win in st.windows:
    let r = taskButtonRect(idx)
    if r.x + r.w > clockRect().x:
      break
    let isActive = (st.activeWin == win) and (wfMinimized notin win.flags)
    var label = win.title
    let maxChars = (r.w - 8) div curFont.width
    if label.len > maxChars:
      label = label[0 ..< maxChars]
    drawFlatButton(r, label, ColText, pressed = isActive, highlighted = false)
    inc idx

  # clock
  let cr = clockRect()
  fb.putRectFilled(cr.x, cr.y, cr.w, cr.h, ColTaskbar)
  drawBevel(cr, ColTaskbarLo, ColTaskbarHi)
  let timeStr = clockString()
  let tw = timeStr.len * curFont.width
  drawGlyphs(cr.x + (cr.w - tw) div 2, cr.y + (cr.h - curFont.height) div 2, timeStr, ColText)

proc repaintDesktop() =
  restoreCursorPixels()
  fb.putRectFilled(0, 0, ScreenW, ScreenH - TaskbarHeight, ColDesktop)
  repaintWindows()
  drawTaskbar()
  saveCursorPixels()
  drawCursor()

proc redraw() =
  repaintDesktop()

####################################################################################################
# demo windows
####################################################################################################

proc spawnAboutWindow() =
  let win = newWindow("About Fusion OS", 430, 220, 420, 220)
  discard win.addLabel("Fusion OS v0.3.0")
  discard win.addLabel("FusionWM - IceWM-style desktop")
  discard win.addButton(150, 120, 120, 28, "OK")
  win.widgets[^1].onClicked = proc (wd: Widget) =
    closeWindow(win)
  st.windows.add(win)
  raiseWindow(win)

proc spawnTerminalWindow() =
  let win = newWindow("Terminal", 60, 80, 520, 320)
  discard win.addLabel("shell: type commands on the physical")
  discard win.addLabel("keyboard; output goes to the debug")
  discard win.addLabel("console (Ctrl+C quits QEMU).")
  discard win.addButton(190, 200, 140, 30, "Exit to Text")
  win.widgets[^1].onClicked = proc (wd: Widget) =
    # leaving the GUI resumes the text console (see exitGui below)
    st.shutdownRequested = true
  st.windows.add(win)
  raiseWindow(win)

proc spawnHelloWindow() =
  let win = newWindow("Hello", 640, 120, 380, 240)
  discard win.addLabel("Welcome to the Fusion desktop!")
  discard win.addButton(40, 120, 130, 30, "About")
  win.widgets[^1].onClicked = proc (wd: Widget) =
    spawnAboutWindow()
    redraw()
  discard win.addButton(200, 120, 130, 30, "Minimize")
  win.widgets[^1].onClicked = proc (wd: Widget) =
    minimizeWindow(win)
    redraw()
  st.windows.add(win)
  raiseWindow(win)

####################################################################################################
# input handling
####################################################################################################

proc onMouseDown(p: Point) =
  # taskbar?
  let sb = startButtonRect()
  if sb.contains(p):
    spawnAboutWindow()
    redraw()
    return

  let tb = taskbarRect()
  if tb.contains(p):
    var idx = 0
    for win in st.windows:
      let r = taskButtonRect(idx)
      if r.contains(p):
        if wfMinimized in win.flags:
          win.flags.excl(wfMinimized)
        raiseWindow(win)
        redraw()
        return
      inc idx
    return

  let win = topmostWindowAt(p)
  if win == nil:
    if st.activeWin != nil:
      st.activeWin.active = false
      st.activeWin = nil
      redraw()
    return

  raiseWindow(win)

  # title bar buttons
  if win.closeButtonRect().contains(p):
    closeWindow(win)
    redraw()
    return
  if win.maximizeButtonRect().contains(p):
    toggleMaximize(win)
    redraw()
    return
  if win.minimizeButtonRect().contains(p):
    minimizeWindow(win)
    redraw()
    return

  # client widgets
  let wd = widgetAt(win, p)
  if wd != nil:
    st.hoverWidget = wd
    redraw()
    return

  # start dragging if grabbed by the title bar
  if win.titleBarRect().contains(p):
    st.drag = DragState(win: win, kind: dkMove, offsetX: p.x - win.rect.x, offsetY: p.y - win.rect.y)

  redraw()

proc onMouseUp(p: Point) =
  if st.drag.kind == dkMove:
    st.drag = DragState(kind: dkNone)
    redraw()
    return

  if st.hoverWidget != nil:
    let wd = st.hoverWidget
    st.hoverWidget = nil
    if wd.rect.contains(p) and wd.onClicked != nil:
      wd.onClicked(wd)
    redraw()

proc handleMouse(ev: mouse.MouseEvent) =
  st.mouseX = clamp(st.mouseX + ev.dx, 0, ScreenW - 1)
  st.mouseY = clamp(st.mouseY + ev.dy, 0, ScreenH - 1)
  let downNow = mouse.Left in ev.buttons
  let wasDown = st.leftWasDown
  st.mouseButtons = ev.buttons
  st.leftWasDown = downNow
  let p = Point(x: st.mouseX, y: st.mouseY)

  if downNow and not wasDown:
    onMouseDown(p)
  elif wasDown and not downNow:
    onMouseUp(p)
  elif downNow and wasDown and st.drag.kind == dkMove:
    # move the window
    let win = st.drag.win
    win.rect.x = clamp(p.x - st.drag.offsetX, 0, ScreenW - win.rect.w)
    win.rect.y = clamp(p.y - st.drag.offsetY, 0, workArea().h - win.rect.h)
    win.relayout()
    redraw()
  elif ev.dx != 0 or ev.dy != 0:
    # just pointer motion: blit the cursor
    restoreCursorPixels()
    saveCursorPixels()
    drawCursor()

proc handleKey(ev: KeyEvent) =
  if ev.eventType != KeyDown:
    return
  case ev.ch
  of '\x1B':  # ESC: exit the GUI and return to the text console
    st.shutdownRequested = true
  else:
    discard

####################################################################################################
# main loop
####################################################################################################

proc start*(chid: int) {.cdecl.} =
  ## Entry point for the FusionWM kernel task.
  logger.info "starting FusionWM (IceWM-style window manager)"

  # make sure the framebuffer is up (console.init already set the mode; do it
  # again idempotently so the WM can run standalone too)
  fb.init()

  # the keyboard channel is created by the console task (chid passed in); the
  # console task is suspended below, so the WM drains all key events while the
  # GUI runs.
  st.kbdSrcChId = chid
  st.mouseChId = mouse.mouseInit()
  st.mouseX = ScreenW div 2
  st.mouseY = ScreenH div 2
  st.bootMinutes = 8 * 60 + 30  # fake wall clock start

  # suspend the text console task so it doesn't fight us for the screen/keys
  st.consoleTask = findTaskByName("console")
  if st.consoleTask != nil:
    suspendTask(st.consoleTask)
    logger.info "suspended the text console task"
  else:
    logger.info "warning: console task not found"

  # seed the desktop with demo windows
  spawnTerminalWindow()
  spawnHelloWindow()

  redraw()
  logger.info "FusionWM ready; press ESC to exit to the text console"

  while not st.shutdownRequested:
    # non-blocking poll of both input channels; sleep briefly when idle.
    var gotEvent = false

    while true:
      let mev = channels.tryRecv[mouse.MouseEvent](st.mouseChId)
      if mev.isSome:
        handleMouse(mev.get)
        gotEvent = true
      else:
        break

    while true:
      let kev = channels.tryRecv[KeyEvent](st.kbdSrcChId)
      if kev.isSome:
        handleKey(kev.get)
        gotEvent = true
      else:
        break

    # advance the clock ~ once per second (timer ticks are 5ms)
    inc st.tickCount
    if st.tickCount mod 200 == 0:
      inc st.clockMinutes
      redraw()

    if not gotEvent:
      sleep(10)

  ##################################################################
  # exiting: hand the screen back to the text console
  ##################################################################
  restoreCursorPixels()

  # drain any pending key events so the console gets a clean slate
  while channels.tryRecv[KeyEvent](st.kbdSrcChId).isSome:
    discard

  if st.consoleTask != nil:
    taskmgr.resume(st.consoleTask)
    logger.info "resumed the text console task"

  logger.info "FusionWM exited; returning control to the text console"
  suspend()
