#[
  PS/2 mouse driver (auxiliary device of the 8042 keyboard controller).

  Produces MouseEvents on a kernel channel, just like the keyboard driver does
  with KeyEvents. The auxiliary port is enabled lazily from within the IRQ12
  interrupt handler (writing to the 8042 command port from IRQ1 could race with
  the output-buffer-full condition of the keyboard port).
]#
import std/strformat

import ports
import kernel/channels
import kernel/idt
import kernel/ioapic
import kernel/lapic

let
  logger = DebugLogger(name: "mouse")

const
  MouseInterruptVector = 0x2c'u8  # irq 12 => vector 0x2c

  # 8042 keyboard controller ports
  CtrlDataPort       = 0x60'u16
  CtrlStatusPort     = 0x64'u16
  CtrlCommandPort    = 0x64'u16

  CmdReadConfigByte  = 0x20
  CmdWriteConfigByte = 0x60
  CmdEnableAux       = 0xA8
  CmdAuxDevice       = 0xD4

  ConfigBitAuxIntf   = 0x02  # auxiliary (mouse) interface enable
  ConfigBitAuxClock  = 0x04  # auxiliary clock line: 0 = enabled

  StatusBitOutputBuf = 0x01
  StatusBitInputBuf  = 0x02

  AuxAck             = 0xFA
  AuxResend          = 0xFE

type
  MouseButton* = enum
    Left = 0
    Right = 1
    Middle = 2

  MouseEvent* = object
    dx*: int       ## relative movement since last packet
    dy*: int
    buttons*: set[MouseButton]

type
  InitState = enum
    msIdle          ## aux interface fully enabled; handling packets
    msWaitAck       ## waiting for the ACK of CmdEnableAux
    msReadConfig    ## config byte requested; next output byte is the value
    msWaitCfgAck    ## waiting for the ACK of the config-byte write

var
  mouseChId: int
  initState: InitState = msIdle
  packet: array[3, uint8]
  packetIndex = 0

proc kbdOutputReady(): bool =
  (portIn8(CtrlStatusPort) and StatusBitOutputBuf) != 0

proc kbdWriteCmd(cmd: uint8) =
  while (portIn8(CtrlStatusPort) and StatusBitInputBuf) != 0:
    discard
  portOut8(CtrlCommandPort, cmd)

proc kbdWriteData(data: uint8) =
  while (portIn8(CtrlStatusPort) and StatusBitInputBuf) != 0:
    discard
  portOut8(CtrlDataPort, data)

proc auxWrite(data: uint8) =
  # send a command to the mouse device via the controller
  kbdWriteCmd(CmdAuxDevice)
  kbdWriteData(data)
  # drain the device's ACK byte from the controller output buffer so it can't
  # be mistaken for a scancode/packet byte later
  if kbdOutputReady():
    let ack = portIn8(CtrlDataPort)
    if ack != AuxAck:
      logger.info &"unexpected aux write response {ack:02x}"

proc mouseInterruptHandler*(intFrame: ptr InterruptFrame)
    {.cdecl, codegenDecl: "__attribute__ ((interrupt)) $# $#$#".} =

  # NOTE: this runs in interrupt context; never block on the 8042 here.
  if initState != msIdle:
    # drive the aux-interface enable handshake using bytes that arrive as
    # interrupts (the controller raises IRQ12 when its output buffer fills)
    if not kbdOutputReady():
      lapic.eoi()
      return
    let resp = portIn8(CtrlDataPort)
    case initState
    of msWaitAck:
      if resp == AuxAck:
        kbdWriteCmd(CmdReadConfigByte)
        initState = msReadConfig
      else:
        initState = msIdle
        logger.info &"aux enable not acknowledged (got {resp:02x})"
    of msReadConfig:
      var cfg = resp
      cfg = cfg or ConfigBitAuxIntf
      cfg = cfg and not uint8(ConfigBitAuxClock)
      kbdWriteCmd(CmdWriteConfigByte)
      kbdWriteData(cfg)
      initState = msWaitCfgAck
    of msWaitCfgAck:
      initState = msIdle
      logger.info "ps/2 auxiliary (mouse) interface enabled"
    of msIdle:
      discard
    lapic.eoi()
    return

  let b = portIn8(CtrlDataPort)
  case b
  of AuxAck, AuxResend, 0xFC, 0xAA:
    discard  # device command response; ignore
  else:
    if (b and 0x08) == 0:
      # not a valid packet first byte; resync
      packetIndex = 0
      lapic.eoi()
      return

    packet[packetIndex] = b
    inc packetIndex
    if packetIndex == 3:
      packetIndex = 0
      var buttons: set[MouseButton] = {}
      if (packet[0] and 0x01) != 0: buttons.incl(Left)
      if (packet[0] and 0x02) != 0: buttons.incl(Right)
      if (packet[0] and 0x04) != 0: buttons.incl(Middle)

      var dx = packet[1].int
      if (packet[0] and 0x10) != 0:
        dx -= 256
      var dy = packet[2].int
      if (packet[0] and 0x20) != 0:
        dy -= 256
      # y axis grows upwards in the ps/2 protocol; screen coords grow downwards
      dy = -dy

      let evt = MouseEvent(dx: dx, dy: dy, buttons: buttons)
      discard channels.send(mouseChId, evt)

  lapic.eoi()

proc mouseInit*(): int =
  ## Initialize the PS/2 mouse driver and return the channel id for mouse events.

  # create a channel to send mouse events
  mouseChId = channels.createKernelChannel[MouseEvent](mode = ChannelMode.Write)
  logger.info &"created mouse channel id = {mouseChId} for mouse events"

  # install the mouse interrupt handler: interrupt input 12 (PS/2 aux) => vector 2Ch
  idt.installHandler(MouseInterruptVector, mouseInterruptHandler)
  ioapic.setRedirEntry(irq = 12, vector = MouseInterruptVector)

  # ask the 8042 controller to enable the auxiliary port; the handshake
  # completes from within the IRQ12 handler (we must not block there)
  kbdWriteCmd(CmdEnableAux)
  initState = msWaitAck

  # enable reporting on the mouse itself
  auxWrite(0xF4)

  logger.info &"installed mouse interrupt handler ({MouseInterruptVector:0>2x}h)"

  result = mouseChId
