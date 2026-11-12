# Tablet as a pad: the link between the PC and the tablet

**Current version: 2** (see "Version 2" below: the handshake and encryption). The message types and their
payloads in between are the same in both versions; in version 2 they travel inside SEALED messages.

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
| 0x01 | HELLO | Version 1 (replaced, see Version 2): UTF-8 JSON `{"code":"123456","device":"iPad","version":1}`. First message, always. |
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

## Version 2: encrypted, and the tablet knows which PC it is talking to

Pictures of the screen may show patient images, and lecture-hall Wi-Fi is shared. Version 2 encrypts every
message after the hello, the code never crosses the network, and a tablet notices a different machine
pretending to be a PC it has paired with before.

1. The PC has one P-256 key pair of its own, kept between runs (Windows: in the user's key store). Its **PC
   check** is the first 4 bytes of SHA-256 of its 65-byte public key, shown as 8 hex digits `XXXX-XXXX` next to
   the code. The tablet makes a fresh P-256 key pair for every connection.
2. Tablet → PC: HELLO (0x01) JSON `{"device":"iPad","version":2,"key":"<base64 of its public key, 65 bytes 04|X|Y>"}`
   (no code). At most 1 KB, within 3 s of connecting.
3. PC → tablet: CHALLENGE (0x86) JSON `{"key":"<base64 of the PC's own public key>","salt":"<base64 of 16 random bytes>","name":"LAPTOP"}`
   — or REJECT (locked out after wrong codes, a broken hello, an old tablet).
4. The tablet compares the PC's key with the one it remembers for that PC (by name): the first time it shows the
   PC check so the presenter can compare it with the PC's screen, and remembers the key; if it differs from the
   remembered one it stops and warns ("not the PC you paired with: if you didn't reinstall Contrast Ink on it,
   don't connect"), offering to connect anyway.
5. Both: `shared` = SHA-256 of the ECDH result (its 32-byte x coordinate, big-endian) — the form Windows'
   `DeriveKeyFromHash` gives, which every platform can compute the same way;
   `keys` = HKDF-SHA256(ikm = shared, salt = salt, info = UTF-8 `"contrastink pad v2 " + code`, 64 bytes);
   tablet→PC key = keys[0..32], PC→tablet key = keys[32..64]. The code is in `info`: with the wrong code the keys
   differ.
6. Tablet → PC: PROOF (0x04), whose payload is a sealed COMMAND `"hello"` (sealing below). If the PC can't open
   it, the code was wrong (counted against guessing) and it answers REJECT in the clear and closes. If it can, it
   answers WELCOME, sealed, and the session is open. A new session with the right code **replaces** a connected
   tablet (the same tablet reconnecting after a Wi-Fi drop, before the PC noticed the old connection was gone).
7. From then on every message both ways is SEALED (0x7F): payload = `nonce (12 bytes) | AES-256-GCM ciphertext of
   the inner message (its 5-byte header and payload) | 16-byte tag`, no associated data. The nonce is 4 zero bytes
   then a big-endian 64-bit counter, from 1, one counter per direction (PROOF uses tablet→PC counter 1); a receiver
   refuses a counter not greater than the last it accepted (a replay), and closes.

A PC that receives a version-1 HELLO (with a code) answers REJECT "Please update Contrast Ink on the tablet."

Limits the PC enforces (tablets need not, but must not exceed them): HELLO ≤ 1 KB within 3 s of connecting; at
most 4 connections not yet in; 5 wrong codes in a row lock everyone out for 30 s; 20 wrong codes make a new code;
silence over 10 s closes; a tablet that can't take messages for 3 s is dropped.

REJECT texts the PC sends: "Please update Contrast Ink on the tablet.", "Too many wrong codes: wait 30 seconds,
then try again.", "Wrong code: type the code Contrast Ink shows on the PC (⚙ Settings)."

What it protects against: anyone listening on the Wi-Fi sees neither the screen nor the code; a machine
advertising itself under a paired PC's name is caught by its key. What it does not: at the very first pairing, a
machine pretending to be the PC could collect a PROOF and try every code offline — compare the PC check on both
screens the first time. A private network or the PC's own hotspot remains the safest choice for patient images.

### Version 2 test vectors (hex; every implementation's tests assert these)

    tablet private key  1111111111111111111111111111111111111111111111111111111111111111
    PC private key      2222222222222222222222222222222222222222222222222222222222222222
    salt                000102030405060708090A0B0C0D0E0F
    code                123456
    tablet public key   040217E617F0B6443928278F96999E69A23A4F2C152BDF6D6CDF66E5B80282D4ED194A7DEBCB97712D2DDA3CA85AA8765A56F45FC758599652F2897C65306E5794
    PC public key       04D65A93977CAA3D1B081852FF57A79E465F1660577304BAEAD505DD3A48589CF350185E895372DF6221EA3A137557E473FDDB6755F05BD507C3C533FCE9C91285
    tablet->PC key      DF563C024C91B19647C1653F3A8E43A1F43779F68708CF133853BCD3BC3A5A98
    PC->tablet key      A848F926D9916CEE78F6203D58A043C11A99389BE63198DE580581A4CBAAB8D2
    first sealed PROOF  0000000000000000000000012DCC2D016D67988C73F5CD844EA2BE5AFB2499203A49A95C4546
                        (the PROOF payload: COMMAND "hello" sealed with the tablet->PC key, counter 1)
    PC check            6FC6-6A90
