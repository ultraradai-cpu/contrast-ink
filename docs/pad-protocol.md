# Tablet as a pad: the link between the PC and the tablet

The PC (Windows; later Mac) runs Contrast Ink as usual. A tablet (Android or iPad) running Contrast Ink in
**Pad** mode shows a live picture of the PC's screen; what is drawn on the tablet is drawn by the PC on its
drawing layer, so OBS records it. Version 1.

## Finding the PC (same Wi-Fi)

- The PC advertises itself on the network with DNS-SD (Bonjour / mDNS), service type **`_contrastink._tcp`**,
  instance name = the computer's name, port = its TCP port, TXT record `v=1`. (Not a UDP broadcast: an iPad app
  may only send broadcasts with a permission Apple must grant, which a sideloaded app can't have. iPad browses
  with NWBrowser, Android with NsdManager, Windows registers with DnsServiceRegister.)
- The tablet lists the PCs by name; the presenter picks one and types the **6-digit code** the PC shows.
- A tablet may also be given an address by hand (`192.168.1.20` or `192.168.1.20:47820`): it shows the PC's
  address under the code, for networks that block mDNS.

## The connection

TCP, the PC listening on port **47820** (or the next free one, as it advertises). Every message:

    [type: 1 byte][length: 4 bytes, big-endian, unsigned][payload: length bytes]

Numbers inside payloads are big-endian. `f32` is an IEEE 754 single. Coordinates are **fractions of the PC's
screen** (0 = left/top edge, 1 = right/bottom edge) of the screen the PC draws on, so the tablet needs no pixels.

### Tablet → PC

| Type | Name | Payload |
|---|---|---|
| 0x01 | HELLO | UTF-8 JSON `{"code":"123456","device":"iPad","version":1}`. First message, always. |
| 0x02 | PING | empty (every 2 s; the PC answers PONG) |
| 0x03 | FRAME_ACK | empty: the last FRAME is on screen, send the next |
| 0x10 | STROKE_BEGIN | `f32 x, f32 y, u8 end` (end: 0 = the pen's tip or a finger, 1 = the pen's eraser end) |
| 0x11 | STROKE_POINTS | `u16 n`, then n × (`f32 x, f32 y`) |
| 0x12 | STROKE_END | empty |
| 0x13 | STROKE_CANCEL | empty (a palm, a second finger: drop the stroke) |
| 0x14 | HOVER | `f32 x, f32 y` (the pen above the glass: the laser's dot) |
| 0x15 | HOVER_END | empty |
| 0x20 | COMMAND | UTF-8, one of: `undo`, `clear`, `next`, `previous`, `tool:pen`, `tool:highlighter`, `tool:arrow`, `tool:oval`, `tool:eraser`, `tool:laser`, `color:N` (0-5), `width:N` (0-2), `opacity:F` (0.1-1), `fade:on`, `fade:off` |

A stroke uses the PC's current tool, colour, width and opacity (the tablet changes them with COMMAND), so the
PC is the one place they live. With the laser, a stroke is the laser's line and HOVER its dot.

### PC → tablet

| Type | Name | Payload |
|---|---|---|
| 0x81 | WELCOME | UTF-8 JSON `{"name":"LAPTOP","screenW":1920,"screenH":1080,"version":1}` |
| 0x82 | REJECT | UTF-8 reason for the presenter (`Wrong code`, `Another tablet is connected`...); then the PC closes |
| 0x83 | FRAME | a JPEG of the screen (at most 1600 px wide). One at a time: the next comes after FRAME_ACK. |
| 0x84 | STATE | UTF-8 JSON `{"tool":"pen","color":0,"width":1,"opacity":1.0,"fading":false,"canUndo":true}` (sent after WELCOME and whenever one changes) |
| 0x85 | PONG | empty |

The PC sends a FRAME about 10 times a second while acknowledged. The tablet shows its own stroke as it draws
(instantly), and lets it go a moment after the pen lifts: the PC's picture has it by then.

Unknown types are skipped (their length says how far). A length over 16 MB closes the connection.

## Test vectors (every implementation's tests use these bytes)

- HELLO `{"code":"123456","device":"t","version":1}`:
  `01 00 00 00 2A` + the 42 UTF-8 bytes of the JSON
- STROKE_BEGIN x=0.5, y=0.25, end=0: `10 00 00 00 09 3F 00 00 00 3E 80 00 00 00`
- STROKE_POINTS (0.5, 0.5), (1, 0): `11 00 00 00 12 00 02 3F 00 00 00 3F 00 00 00 3F 80 00 00 00 00 00 00`
- STROKE_END: `12 00 00 00 00`
- COMMAND `undo`: `20 00 00 00 04 75 6E 64 6F`
- FRAME_ACK: `03 00 00 00 00`
