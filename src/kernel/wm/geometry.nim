#[
  Basic 2D geometry helpers for the window manager
]#

type
  Point* = object
    x*, y*: int

  Size* = object
    w*, h*: int

  Rect* = object
    x*, y*, w*, h*: int

proc `right`*(r: Rect): int {.inline.} = r.x + r.w
proc `bottom`*(r: Rect): int {.inline.} = r.y + r.h

proc contains*(r: Rect, p: Point): bool {.inline.} =
  p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h

proc intersects*(a, b: Rect): bool {.inline.} =
  not (a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y)

proc intersection*(a, b: Rect): Rect {.inline.} =
  let x1 = max(a.x, b.x)
  let y1 = max(a.y, b.y)
  let x2 = min(a.x + a.w, b.x + b.w)
  let y2 = min(a.y + a.h, b.y + b.h)
  if x2 <= x1 or y2 <= y1:
    Rect(x: 0, y: 0, w: 0, h: 0)
  else:
    Rect(x: x1, y: y1, w: x2 - x1, h: y2 - y1)

proc clamp*[T](v, lo, hi: T): T {.inline.} =
  if v < lo: lo elif v > hi: hi else: v
