#[
  Window objects for the IceWM-style window manager.

  Each window has a title bar (title + minimize/maximize/close buttons, like
  IceWM's default decorations) and a client area that can host simple widgets.
  Windows render directly to the shared framebuffer through the primitives in
  con/framebuffer.
]#

import con/[framebuffer as fb, font]
import wm/geometry
import wm/widget

export geometry, widget

const
  ScreenW* = 1280
  ScreenH* = 960

const
  TitleBarHeight* = 24
  BorderSize* = 1
  CloseButtonSize = 16
  MinMaxButtonSize = 16
  ButtonGap = 3
  ClientPad = 8

  ColTitleActive = 0x31578Du32     # IceWM-ish blue gradient base
  ColTitleActive2 = 0x4A76B4'u32
  ColTitleInactive = 0x6E7B88'u32
  ColTitleText = 0xFFFFFF'u32
  ColBorder = 0x1F2730'u32
  ColFace = 0xC3CBD6'u32           # window face / button gray
  ColFaceDark = 0x9AA5B1'u32
  ColBevelLight = 0xE8EDF2'u32
  ColBevelDark = 0x6C7683'u32
  ColText = 0x182028'u32
  ColLabelBg = 0xDDE3EA'u32

type
  WindowFlag* = enum
    wfMinimized
    wfMaximized

  Window* = ref object
    id*: int
    title*: string
    rect*: Rect            ## full window frame (incl. title bar & border)
    restoreRect*: Rect     ## rect before maximizing
    flags*: set[WindowFlag]
    widgets*: seq[Widget]
    onClose*: proc (w: Window) {.closure.}
    onMinimize*: proc (w: Window) {.closure.}
    onMaximize*: proc (w: Window) {.closure.}
    active*: bool

var
  nextWindowId = 1
  curFont = dina15x7

proc clientRect*(win: Window): Rect {.inline.} =
  Rect(
    x: win.rect.x + BorderSize,
    y: win.rect.y + TitleBarHeight,
    w: win.rect.w - 2 * BorderSize,
    h: win.rect.h - TitleBarHeight - BorderSize,
  )

proc titleBarRect*(win: Window): Rect {.inline.} =
  Rect(x: win.rect.x, y: win.rect.y, w: win.rect.w, h: TitleBarHeight)

proc closeButtonRect*(win: Window): Rect {.inline.} =
  let r = win.rect
  Rect(
    x: r.x + r.w - BorderSize - ButtonGap - CloseButtonSize,
    y: r.y + (TitleBarHeight - CloseButtonSize) div 2,
    w: CloseButtonSize, h: CloseButtonSize,
  )

proc maximizeButtonRect*(win: Window): Rect {.inline.} =
  let c = win.closeButtonRect
  Rect(x: c.x - ButtonGap - MinMaxButtonSize, y: c.y, w: MinMaxButtonSize, h: MinMaxButtonSize)

proc minimizeButtonRect*(win: Window): Rect {.inline.} =
  let m = win.maximizeButtonRect
  Rect(x: m.x - ButtonGap - MinMaxButtonSize, y: m.y, w: MinMaxButtonSize, h: MinMaxButtonSize)

proc newWindow*(title: string, x, y, w, h: int): Window =
  result = Window(
    id: nextWindowId,
    title: title,
    rect: Rect(x: x, y: y, w: w, h: h),
    restoreRect: Rect(x: x, y: y, w: w, h: h),
  )
  inc nextWindowId

proc addWidget(win: Window, wd: Widget) =
  win.widgets.add(wd)

proc addButton*(win: Window, cx, cy, w, h: int, label: string): Widget =
  ## Add a button positioned relative to the window's client area origin.
  let cl = win.clientRect
  let btn = newButton(cl.x + cx, cl.y + cy, w, h, label)
  win.addWidget(btn)
  btn

proc addLabel*(win: Window, text: string): Widget =
  let lbl = newLabel(text)
  win.addWidget(lbl)
  lbl

proc relayout*(win: Window) =
  ## Recompute absolute widget positions (after move/resize).
  let cl = win.clientRect
  var y = cl.y + ClientPad
  for i in 0 ..< win.widgets.len:
    var wd = win.widgets[i]
    case wd.kind
    of wkButton:
      wd.rect.x = cl.x + ClientPad + (i mod 2) * (cl.w div 2)
      wd.rect.y = y
      if i mod 2 == 1:
        y += wd.rect.h + 8
    of wkLabel:
      wd.rect = Rect(x: cl.x + ClientPad, y: y, w: cl.w - 2 * ClientPad, h: curFont.height + 4)
      y += wd.rect.h + 4

proc drawBevel(r: Rect, light, dark: uint32) =
  fb.putRect(r.x, r.y, r.w, r.h, light)
  fb.putPixel(r.x + r.w - 1, r.y, dark)
  for j in 0 ..< r.h:
    fb.putPixel(r.x + r.w - 1, r.y + j, dark)
  for i in 0 ..< r.w:
    fb.putPixel(r.x + i, r.y + r.h - 1, dark)

proc drawGlyphs*(x, y: int, s: string, color: uint32) =
  var px = x
  for ch in s.items:
    if ch != ' ':
      let glyph = getGlyph(curFont, ch)
      for i in 0 ..< curFont.height:
        for j in 0 ..< curFont.width:
          if (glyph[i] shr (7 - j) and 1) == 1:
            if px + j >= 0 and px + j < ScreenW and y + i >= 0 and y + i < ScreenH:
              fb.putPixel(px + j, y + i, color)
    px += curFont.width

proc drawTitleButtonIcon(r: Rect, kind: int, color: uint32) =
  # kind: 0 = close (X), 1 = minimize (_), 2 = maximize (square)
  case kind
  of 0:
    for i in 2 ..< r.w - 2:
      fb.putPixel(r.x + i, r.y + i, color)
      fb.putPixel(r.x + i, r.y + r.h - 1 - i, color)
  of 1:
    for i in 3 ..< r.w - 3:
      fb.putPixel(r.x + i, r.y + r.h - 5, color)
  else:
    for i in 0 ..< r.w:
      fb.putPixel(r.x + i, r.y + 3, color)
      fb.putPixel(r.x + i, r.y + r.h - 4, color)
    for i in 0 ..< r.h:
      fb.putPixel(r.x, r.y + i, color)
      fb.putPixel(r.x + r.w - 1, r.y + i, color)

proc drawButtonSurface(r: Rect, label: string, color: uint32) =
  fb.putRectFilled(r.x, r.y, r.w, r.h, ColFace)
  drawBevel(r, ColBevelLight, ColBevelDark)
  if label.len > 0:
    let tw = label.len * curFont.width
    var tx = r.x + (r.w - tw) div 2
    var ty = r.y + (r.h - curFont.height) div 2
    if tx < r.x: tx = r.x
    if ty < r.y: ty = r.y
    drawGlyphs(tx, ty, label, color)

proc draw*(win: Window) =
  if wfMinimized in win.flags:
    return

  let r = Rect(
    x: max(0, win.rect.x),
    y: max(0, win.rect.y),
    w: min(win.rect.w, ScreenW - max(0, win.rect.x)),
    h: min(win.rect.h, ScreenH - max(0, win.rect.y)),
  )
  if r.w <= 0 or r.h <= 0:
    return

  # border
  fb.putRectFilled(r.x, r.y, r.w, r.h, ColBorder)

  # title bar with a simple two-tone gradient
  let tbY = r.y + BorderSize
  let tbH = TitleBarHeight - BorderSize
  let half = tbH div 2
  fb.putRectFilled(r.x + BorderSize, tbY, r.w - 2 * BorderSize, half,
    if win.active: ColTitleActive2 else: ColTitleInactive)
  fb.putRectFilled(r.x + BorderSize, tbY + half, r.w - 2 * BorderSize, tbH - half,
    if win.active: ColTitleActive else: ColTitleInactive)

  # title text
  drawGlyphs(r.x + BorderSize + 6, tbY + (tbH - curFont.height) div 2, win.title, ColTitleText)

  # window control buttons (minimize / maximize / close)
  drawButtonSurface(win.minimizeButtonRect(), "", ColText)
  drawTitleButtonIcon(win.minimizeButtonRect(), 1, ColText)
  drawButtonSurface(win.maximizeButtonRect(), "", ColText)
  drawTitleButtonIcon(win.maximizeButtonRect(), 2, ColText)
  drawButtonSurface(win.closeButtonRect(), "", 0xB03030'u32)
  drawTitleButtonIcon(win.closeButtonRect(), 0, 0xB03030'u32)

  # client area
  let cl = win.clientRect
  fb.putRectFilled(cl.x, cl.y, cl.w, cl.h, ColLabelBg)

  # widgets
  for wd in win.widgets:
    case wd.kind
    of wkButton:
      drawButtonSurface(wd.rect, wd.label, ColText)
    of wkLabel:
      fb.putRectFilled(wd.rect.x, wd.rect.y, wd.rect.w, wd.rect.h, ColFace)
      drawBevel(wd.rect, ColBevelDark, ColBevelLight)
      drawGlyphs(wd.rect.x + 4, wd.rect.y + 2, wd.label, ColText)
