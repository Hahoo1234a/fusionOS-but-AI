#[
    Framebuffer support for console output
]#

import drivers/bga

type
  Framebuffer* = object
    mem: ptr UncheckedArray[uint32]
    width: int
    height: int
    pitch: int
    bpp: int

const
  XRes = 1280
  YRes = 960
  DefaultBackground = 0x608aaf'u32

var
  fb: Framebuffer

proc init*() =
  bga.setResolution(XRes, YRes)
  fb = Framebuffer(
    mem: bga.getFramebuffer(),
    width: XRes,
    height: YRes,
    pitch: XRes,
    bpp: 32
  )

proc getWidth*(): int =
  fb.width

proc getHeight*(): int =
  fb.height

proc clear*(color: uint32 = DefaultBackground) =
  for i in 0 ..< fb.width * fb.height:
    fb.mem[i] = color

proc getPixel*(x, y: int): uint32 {.inline.} =
  if x < 0 or y < 0 or x >= fb.width or y >= fb.height:
    return 0
  fb.mem[y * fb.pitch + x]

proc putPixel*(x, y: int, color: uint32) {.inline.} =
  # the framebuffer is mapped for the full virtual resolution (double height
  # when using a back buffer); clip only horizontally and to non-negative y so
  # callers like gfxsrv can write past YRes into the second half of video mem.
  if x < 0 or y < 0 or x >= fb.pitch:
    return
  fb.mem[y * fb.pitch + x] = color

proc putRectFilled*(x, y: int, width, height: int, color: uint32) =
  for i in 0 ..< width:
    for j in 0 ..< height:
      putPixel(x + i, y + j, color)

proc putRect*(x, y: int, width, height: int, color: uint32) =
  for i in 0 ..< width:
    putPixel(x + i, y, color)
    putPixel(x + i, y + height - 1, color)
  for i in 0 ..< height:
    putPixel(x, y + i, color)
    putPixel(x + width - 1, y + i, color)
