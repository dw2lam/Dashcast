# Dashcast wire protocol (v1)

One WebSocket per car. Two automatic modes:
- **HTTP mode** (the default: no own domain, or no certificate for it yet): `http://203.0.113.77` →
  `ws://…/ws` on :80. Not a secure context → no WebCodecs → media goes over **WebRTC**; the WebSocket stays for control/input.
  Other hostnames that reach :80 are redirected to `http://203.0.113.77/`.
- **HTTPS mode** (optional: the user's own domain, e.g. `car.yourdomain.com`, has a valid certificate):
  `https://car.yourdomain.com` → `wss://…/ws` on 203.0.113.77:443. Secure context → WebCodecs. `http://` on :80
  redirects here (except connectivity-check hosts). The certificate comes from Let's Encrypt (DNS-01, Cloudflare
  domains) or is imported by the user (any other DNS provider); its hostname is the one the server accepts.
- Dev: `ws://localhost:8080/ws` (localhost is a secure context).
The Mac answers DNS itself (local responder on 203.0.113.77:53530, for the own domain if one is set and the
Tesla/Apple connectivity checks; pf on bridge100 redirects the car's port-53 traffic to it), so neither mode needs internet.
The page itself is served at `/` from the same origin. `GET /healthz` → `ok`.

All times are **server clock microseconds** (`DashClock.nowMicros()`, host-time based)
unless a field says otherwise. The client estimates `offset = serverTime - performance.now()*1000`
from ping/pong (keep the sample with the lowest RTT of the last ~20).

## Binary messages (server → client)

16-byte header, **big-endian**, then payload:

| offset | size | field |
|---|---|---|
| 0 | u8  | `type` |
| 1 | u8  | `flags` — bit0 = keyframe |
| 2 | u16 | reserved (0) |
| 4 | u32 | `seq` — per-type sequence number (video and audio count separately) |
| 8 | u64 | `pts` — server µs of capture |

| type | payload |
|---|---|
| 1 `videoH264` | H.264 access unit, **Annex B** (start codes). Keyframes carry SPS+PPS inline. No B-frames. Feed to `VideoDecoder` configured **without** `description`. |
| 2 `videoHEVC` | Same, HEVC Annex B (VPS+SPS+PPS on keyframes). |
| 3 `videoJPEG` | One baseline JPEG image. Always a "keyframe". |
| 4 `audioPCM`  | Interleaved **s16le** stereo @ 48 kHz, normally 480 frames (10 ms). `pts` = first sample. |

## Text (JSON) messages

Every message has `"t"`.

### server → client
- `{"t":"config","transport":"ws"|"webrtc","codec":"avc1.4D4020"|"hvc1.1.6.L120.B0"|"jpeg","width":1280,"height":720,"fps":30,"bitrateKbps":6000,"tier":"mcu2","latencyMode":"interactive"|"cinema","audio":{"sampleRate":48000,"channels":2}|null,"inputEnabled":true,"serverTime":123}`
  Sent after `hello` and whenever the stream is reconfigured. Client must (re)configure its decoder and canvas; a keyframe follows.
- `{"t":"pong","id":7,"clientTime":12.5,"serverTime":123456}` — `clientTime` echoed as sent (ms, performance.now()).
- `{"t":"mode","latencyMode":"cinema"}` — latency mode changed without a reconfigure.
- `{"t":"bye","reason":"stopped"}`
- `{"t":"host","state":"active"|"locked"|"displayAsleep"|"sleeping"}` — whether the Mac can show anything.
  Sent when the screen locks/unlocks, the displays sleep/wake, and from the Mac's `willSleep`
  (`sleeping`, before the network goes away); repeated right after a `config` while it isn't `active`.
  The client shows a calm full-screen message ("Your Mac is locked. Unlock it to keep streaming.",
  "Your Mac went to sleep. Wake it to reconnect.") and clears it on `active` or a new `config`. If the
  socket dies after `sleeping`, the client keeps that message instead of a generic error while it retries.
- `{"t":"rtcOffer","sdp":"v=0…"}` — webrtc transport only, after `config`. Complete SDP (no trickle): sendonly H.264
  (constrained baseline, packetization-mode=1) + Opus 48k stereo. Server candidates are on 203.0.113.77 only.

### client → server
- `{"t":"hello","version":1,"ua":"...","viewport":{"w":1920,"h":1200,"dpr":1.0},"caps":{...},"bench":{...}}`
  - `caps`: `{"secure":bool,"webrtc":bool,"webcodecs":bool,"h264":{"high":bool,"main":bool,"baseline":bool},"hevc":bool,"hwAccel":"yes"|"no"|"unknown","audioWorklet":bool,"offscreenCanvas":bool,"webgl":bool}`
  - `bench`: `{"h264_720p_decodeMs":number|null,"h264_1080p_decodeMs":number|null,"jpegDecodeMs":number|null}` (mean ms/frame)
- `{"t":"ping","id":7,"clientTime":12.5}` — every 1 s (every 250 ms for the first 2 s).
- `{"t":"ack","seq":42,"recvAt":123456,"decodeMs":3.1,"presented":true}` — one per video frame. `recvAt` is the client's receive time **converted to server µs**.
- `{"t":"stats","fps":29.8,"decodeMs":4.2,"dropped":1,"queue":0,"latencyMs":61,"audioBufferMs":40}` — every 1 s.
  `dropped` = frames dropped **during that 1 s interval** (acks are also sent for frames dropped before decode, `presented:false`).
- `{"t":"input","kind":"down"|"move"|"up"|"scroll"|"rightClick"|"text"|"key","x":0.5,"y":0.25,"dx":0,"dy":0,"text":null,"key":null}`
  `x`,`y` normalized 0…1 over the video frame (0.5 for `text`/`key`); `dx`,`dy` scroll deltas in CSS px with
  **WheelEvent semantics** (positive `dy` scrolls down; two-finger touch follows natural scrolling). `key` = DOM `KeyboardEvent.key`.
- `{"t":"keyframe"}` — decoder error or gap; server sends an IDR next.
- `{"t":"setLatencyMode","latencyMode":"interactive"|"cinema"|"auto"}`
- `{"t":"rtcAnswer","sdp":"v=0…"}` — after ICE gathering completes (no trickle).

### Disconnects (server)
How the car's socket ended decides what the Mac tells the user:
- a close frame with 1000/1001 (page closed, navigated away) or a TCP FIN → "Browser closed on the car";
- no close frame (reset, error) or no message for 10 s → "Car left the Wi-Fi" when the car's address no
  longer resolves in the Mac's ARP table, otherwise "Connection lost".

### Transport selection (server)
1. `caps.secure && caps.webcodecs && h264` → `ws` (binary frames below, tiers per bench).
2. else `caps.webrtc` → `webrtc`: H.264 constrained baseline, 1280×720@30 on unknown/MCU2 (1920×1080@30 on override),
   Opus audio. No acks; the client reports `stats` from `getStats()` (fps, decodeMs from totalDecodeTime,
   dropped = framesDropped, latencyMs ≈ jitterBufferDelay/jitterBufferEmittedCount + rtt/2). Keyframes via PLI.
   Latency modes map to `receiver.playoutDelayHint` / `jitterBufferTarget` (interactive 0, cinema 0.25 s).
3. else → `ws` with JPEG.

## Latency modes (client playout, ws transport)
- **interactive**: show each video frame as soon as it is decoded; audio playout buffer ~60 ms; no strict lip sync.
- **cinema**: audio playout buffer ~250 ms and is the master clock; a decoded frame is shown when `pts <= audioClockServerUs`, frames later than 1 frame behind are dropped.
- **auto** (server-side policy): cinema while audio is flowing and no input for 3 s, otherwise interactive.
