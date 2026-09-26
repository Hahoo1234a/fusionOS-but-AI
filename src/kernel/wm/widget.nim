#[
  Simple immediate-mode widgets for the window manager (buttons, labels)
]#

import wm/geometry

type
  WidgetKind* = enum
    wkButton
    wkLabel

  Widget* = ref object
    kind*: WidgetKind
    rect*: Rect           ## absolute position on screen (recomputed by the window)
    label*: string
    onClicked*: proc (w: Widget) {.closure.}

proc newButton*(x, y, w, h: int, label: string): Widget =
  Widget(
    kind: wkButton,
    rect: Rect(x: x, y: y, w: w, h: h),
    label: label,
  )

proc newLabel*(label: string): Widget =
  Widget(kind: wkLabel, label: label)
