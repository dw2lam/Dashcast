#!/usr/bin/env node
// Dashcast mock server: speaks PROTOCOL.md closely enough to exercise the web client
// without the Swift app.
//
//   node dev/mock-server.mjs [--jpeg] [--port 8090] [--size 1280x720] [--fps 30]
//                            [--mode interactive|cinema|auto] [--no-audio] [--no-input]
//                            [--delay ms] [--jitter ms] [--verbose] [--hevc] [--webrtc [--rtc-fail]]
//
// --hevc: send videoHEVC (type 2, libx265, AUD-delimited) to clients with caps.hevc.
//
// --webrtc: plain-HTTP "HTTP mode" transport selection per PROTOCOL.md — a client without
// (secure && webcodecs && h264) but with caps.webrtc gets config.transport = "webrtc" and
// an rtcOffer. Media is sent with @roamhq/wrtc (optional dependency) if it loads: the same
// testsrc2 pattern (raw frames from a live ffmpeg lavfi source, encoded by libwebrtc as VP8 —
// the wrtc build has no H.264; the real server sends H.264 constrained baseline) + the beep
// track (Opus).
// Test from localhost with ?forceWebRTC=1 (claims webcodecs:false).
//
// Video: a 10 s testsrc2 loop with a big burned-in running clock, a full-frame white flash
// for 3 frames every 2 s. Audio: a 1 kHz, 100 ms beep every 2 s whose pts matches the
// flash exactly, so A/V sync is visible + audible. Clips are made once with ffmpeg and
// cached in dev/.cache/. H.264 is split into access units on AUD NALs.
//
// stdin (when attached to a terminal): c = cinema, i = interactive, a = auto,
//   r = resend config, k = jump to the next IDR, b = bye + close, q = quit.
// Same over HTTP for scripted tests: GET /control?mode=cinema|interactive|auto,
//   GET /control?cmd=config|idr|bye
import { createServer } from 'node:http';
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf('--' + name);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : def;
};
const flag = (name) => args.includes('--' + name);

const PORT = +opt('port', 8090);
const [W, H] = opt('size', '1280x720').split('x').map(Number);
const FPS = +opt('fps', 30);
const FORCE_JPEG = flag('jpeg');
const AUDIO = !flag('no-audio');
const INPUT = !flag('no-input');
const DELAY = +opt('delay', 0);
const JITTER = +opt('jitter', 0);
const VERBOSE = flag('verbose');
const WEBRTC = flag('webrtc');
const HEVC = flag('hevc');
let modePref = opt('mode', 'interactive');
const FF = process.env.FFMPEG || '/opt/homebrew/bin/ffmpeg';
const LOOP_S = 10;
const FRAME_US = 1e6 / FPS;

const nowUs = () => Number(process.hrtime.bigint() / 1000n); // host-time-like µs
const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a);

// ---- clip generation -------------------------------------------------------------

const cache = join(here, '.cache', `${W}x${H}@${FPS}`);
mkdirSync(cache, { recursive: true });

function filter() {
  // flash first, then the enlarged clock on top so it stays readable during the flash
  const s = Math.max(3, Math.round(W / 210));
  return (
    `[0:v]split=2[a][b];[b]crop=102:38:0:0,scale=${102 * s}:${38 * s}:flags=neighbor[t];` +
    `[a]drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(n,${FPS * 2}),3)'[f];` +
    `[f][t]overlay=(W-w)/2:(H-h)/2`
  );
}

function ensureH264() {
  const out = join(cache, 'clip.h264');
  if (!existsSync(out)) {
    log(`generating ${W}x${H}@${FPS} H.264 clip…`);
    execFileSync(FF, [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', `testsrc2=size=${W}x${H}:rate=${FPS}:duration=${LOOP_S}`,
      '-filter_complex', filter(),
      '-c:v', 'libx264', '-profile:v', 'main', '-preset', 'veryfast', '-tune', 'zerolatency',
      '-bf', '0', '-x264-params', `keyint=${FPS}:min-keyint=${FPS}:scenecut=0:aud=1:repeat-headers=1`,
      '-b:v', '3M', '-maxrate', '3M', '-bufsize', '1M', '-pix_fmt', 'yuv420p',
      '-bsf:v', 'h264_mp4toannexb', '-f', 'h264', out,
    ]);
  }
  const b = readFileSync(out);
  // Split on AUD (nal_unit_type 9) start codes.
  const starts = [];
  for (let i = 0; i + 4 < b.length; i++) {
    if (b[i] === 0 && b[i + 1] === 0 && b[i + 2] === 1 && (b[i + 3] & 0x1f) === 9) {
      starts.push(i > 0 && b[i - 1] === 0 ? i - 1 : i);
      i += 3;
    }
  }
  starts.push(b.length);
  const frames = [];
  let codec = 'avc1.4D401F';
  for (let k = 0; k + 1 < starts.length; k++) {
    const au = b.subarray(starts[k], starts[k + 1]);
    let key = false;
    for (let i = 0; i + 4 < au.length; i++) {
      if (au[i] === 0 && au[i + 1] === 0 && au[i + 2] === 1) {
        const t = au[i + 3] & 0x1f;
        if (t === 5) key = true;
        if (t === 7 && k === 0) codec = 'avc1.' + [au[i + 4], au[i + 5], au[i + 6]].map((x) => x.toString(16).padStart(2, '0').toUpperCase()).join('');
      }
    }
    frames.push({ data: au, key });
  }
  return { codec, frames };
}

function ensureHevc() {
  const out = join(cache, 'clip.hevc');
  if (!existsSync(out)) {
    log(`generating ${W}x${H}@${FPS} HEVC clip…`);
    execFileSync(FF, [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', `testsrc2=size=${W}x${H}:rate=${FPS}:duration=${LOOP_S}`,
      '-filter_complex', filter(),
      '-c:v', 'libx265', '-preset', 'veryfast', '-tune', 'zerolatency', '-profile:v', 'main',
      '-x265-params', `log-level=error:aud=1:repeat-headers=1:bframes=0:keyint=${FPS}:min-keyint=${FPS}:scenecut=0`,
      '-b:v', '2M', '-pix_fmt', 'yuv420p', '-f', 'hevc', out,
    ]);
  }
  const b = readFileSync(out);
  const nal = (i) => (b[i + 3] >> 1) & 0x3f;
  const starts = [];
  for (let i = 0; i + 4 < b.length; i++) {
    if (b[i] === 0 && b[i + 1] === 0 && b[i + 2] === 1 && nal(i) === 35) {
      starts.push(i > 0 && b[i - 1] === 0 ? i - 1 : i);
      i += 3;
    }
  }
  starts.push(b.length);
  const frames = [];
  for (let k = 0; k + 1 < starts.length; k++) {
    const au = b.subarray(starts[k], starts[k + 1]);
    let key = false;
    for (let i = 0; i + 4 < au.length; i++) {
      if (au[i] === 0 && au[i + 1] === 0 && au[i + 2] === 1) {
        const t = (au[i + 3] >> 1) & 0x3f;
        if (t >= 16 && t <= 21) key = true; // IRAP (IDR/CRA/BLA)
      }
    }
    frames.push({ data: au, key });
  }
  return { codec: `hvc1.1.6.L${H > 720 ? 120 : 93}.B0`, type: 2, frames };
}

function ensureJpeg() {
  const dir = join(cache, 'jpeg');
  if (!existsSync(join(dir, '0001.jpg'))) {
    log(`generating ${W}x${H}@${FPS} JPEG frames…`);
    mkdirSync(dir, { recursive: true });
    execFileSync(FF, [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', `testsrc2=size=${W}x${H}:rate=${FPS}:duration=${LOOP_S}`,
      '-filter_complex', filter(),
      '-c:v', 'mjpeg', '-q:v', '6', '-pix_fmt', 'yuvj420p', '-f', 'image2', join(dir, '%04d.jpg'),
    ]);
  }
  const frames = readdirSync(dir).filter((f) => f.endsWith('.jpg')).sort().map((f) => ({ data: readFileSync(join(dir, f)), key: true }));
  return { codec: 'jpeg', frames };
}

// 2 s of s16le stereo: 100 ms 1 kHz beep at t=0, silence after.
const BEEP = (() => {
  const n = 96000;
  const b = Buffer.alloc(n * 4);
  for (let i = 0; i < 4800; i++) {
    const env = Math.min(1, i / 96, (4800 - i) / 96);
    const v = Math.round(Math.sin((2 * Math.PI * 1000 * i) / 48000) * 0.35 * env * 32767);
    b.writeInt16LE(v, i * 4);
    b.writeInt16LE(v, i * 4 + 2);
  }
  return b;
})();

const h264 = FORCE_JPEG && !WEBRTC ? null : ensureH264();
const hevc = HEVC ? ensureHevc() : null;
let wrtc = null;
if (WEBRTC) {
  try {
    wrtc = (await import('@roamhq/wrtc')).default;
  } catch (e) {
    log(`@roamhq/wrtc unavailable (${e.message.split('\n')[0]}): --webrtc will negotiate nothing`);
  }
}
const jpeg = ensureJpeg();
log(`clips ready: ${h264 ? `h264 ${h264.frames.length} AUs (${h264.codec}), ` : ''}${hevc ? `hevc ${hevc.frames.length} AUs (${hevc.codec}), ` : ''}jpeg ${jpeg.frames.length} frames`);

// ---- HTTP ------------------------------------------------------------------------

const server = createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];
  if (url === '/' || url === '/index.html') {
    const f = join(root, 'dist', 'index.html');
    if (!existsSync(f)) {
      res.writeHead(500).end('dist/index.html missing — run `npm run build`');
      return;
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end(readFileSync(f));
  } else if (url === '/healthz') res.writeHead(200).end('ok');
  else if (url === '/control') {
    // Test hook: /control?mode=cinema|interactive|auto  or  /control?cmd=config|idr|bye
    const q = new URL(req.url, 'http://x').searchParams;
    for (const s of sessions) control(s, q.get('mode') || q.get('cmd'));
    res.writeHead(200).end(`ok (${sessions.size} session${sessions.size === 1 ? '' : 's'})`);
  }
  else res.writeHead(404).end('not found');
});

// ---- WebSocket sessions --------------------------------------------------------------

const wss = new WebSocketServer({ noServer: true });
server.on('upgrade', (req, sock, head) => {
  if ((req.url || '').split('?')[0] !== '/ws') return sock.destroy();
  wss.handleUpgrade(req, sock, head, (ws) => wss.emit('connection', ws, req));
});

const sessions = new Set();
let nextId = 1;

function header(type, key, seq, pts) {
  const h = Buffer.alloc(16);
  h.writeUInt8(type, 0);
  h.writeUInt8(key ? 1 : 0, 1);
  h.writeUInt32BE(seq >>> 0, 4);
  h.writeBigUInt64BE(BigInt(Math.round(pts)), 8);
  return h;
}

class Session {
  constructor(ws, addr) {
    this.id = nextId++;
    this.ws = ws;
    this.addr = addr;
    this.clip = null;
    this.out = []; // delayed send queue [{at, data, binary}]
    this.lastOut = 0;
    this.mode = 'interactive';
    this.pref = modePref;
    this.lastInput = 0;
    this.acks = { n: 0, shown: 0, dec: 0, net: 0 };
    this.timer = setInterval(() => this.tick(), 4);
    this.statTimer = setInterval(() => this.second(), 1000);
    ws.on('message', (d, isBinary) => (isBinary ? null : this.onText(d.toString())));
    ws.on('close', () => this.close('socket closed'));
    ws.on('error', () => {});
    log(`[${this.id}] connected from ${addr}`);
  }

  send(data, binary = false) {
    if (!DELAY && !JITTER) return this.ws.readyState === 1 && this.ws.send(data, { binary });
    const at = Math.max(this.lastOut, nowUs() + (DELAY + Math.random() * JITTER) * 1000);
    this.lastOut = at;
    this.out.push({ at, data, binary });
  }

  json(o) {
    this.send(JSON.stringify(o));
  }

  onText(s) {
    let m;
    try {
      m = JSON.parse(s);
    } catch {
      return log(`[${this.id}] bad json: ${s.slice(0, 80)}`);
    }
    switch (m.t) {
      case 'ping':
        this.json({ t: 'pong', id: m.id, clientTime: m.clientTime, serverTime: nowUs() });
        break;
      case 'hello':
        log(`[${this.id}] hello v${m.version} viewport=${JSON.stringify(m.viewport)}\n    ua=${m.ua}\n    caps=${JSON.stringify(m.caps)}\n    bench=${JSON.stringify(m.bench)}`);
        this.start(m);
        break;
      case 'ack': {
        const a = this.acks;
        a.n++;
        if (m.presented) a.shown++;
        a.dec += m.decodeMs || 0;
        a.net += (m.recvAt - (this.ptsOf.get(m.seq) || m.recvAt)) / 1000;
        this.ptsOf.delete(m.seq);
        if (VERBOSE) log(`[${this.id}] ack ${JSON.stringify(m)}`);
        break;
      }
      case 'stats':
        log(`[${this.id}] stats fps=${m.fps} decode=${m.decodeMs}ms dropped=${m.dropped} queue=${m.queue} latency=${m.latencyMs}ms audioBuf=${m.audioBufferMs}ms`);
        break;
      case 'input':
        this.lastInput = Date.now();
        log(`[${this.id}] input ${m.kind} x=${m.x} y=${m.y}` + (m.kind === 'scroll' ? ` dx=${m.dx} dy=${m.dy}` : '') + (m.text != null ? ` text=${JSON.stringify(m.text)}` : '') + (m.key != null ? ` key=${m.key}` : ''));
        if (this.pref === 'auto') this.applyAuto();
        break;
      case 'rtcAnswer':
        log(`[${this.id}] rtcAnswer (${(m.sdp.match(/a=candidate:/g) || []).length} candidates)`);
        // --rtc-fail: ignore the answer so ICE never connects (exercises the client's failure path).
        if (this.pc && !flag('rtc-fail')) this.pc.setRemoteDescription({ type: 'answer', sdp: m.sdp }).catch((e) => log(`[${this.id}] setRemoteDescription failed: ${e.message}`));
        break;
      case 'keyframe':
        log(`[${this.id}] keyframe requested`);
        this.waitIDR = true;
        break;
      case 'setLatencyMode':
        log(`[${this.id}] setLatencyMode ${m.latencyMode}`);
        this.pref = m.latencyMode;
        if (this.pref === 'auto') this.applyAuto();
        else this.setMode(this.pref);
        break;
      default:
        log(`[${this.id}] unknown message ${s.slice(0, 120)}`);
    }
  }

  start(hello) {
    const c = hello.caps || {};
    const canH264 = c.webcodecs && c.h264 && (c.h264.main || c.h264.baseline || c.h264.high);
    // PROTOCOL.md transport selection: secure+webcodecs+h264 -> ws, else webrtc, else ws JPEG.
    if (WEBRTC && wrtc && c.webrtc && !(c.secure !== false && canH264 && !FORCE_JPEG)) return this.startRtc();
    this.clip = !FORCE_JPEG && HEVC && c.webcodecs && c.hevc ? hevc : !FORCE_JPEG && canH264 && h264 ? h264 : jpeg;
    this.ptsOf = new Map();
    this.sendConfig();
  }

  async startRtc() {
    this.mode = this.pref === 'cinema' ? 'cinema' : 'interactive';
    this.json({
      t: 'config', transport: 'webrtc', codec: 'vp8', width: W, height: H, fps: FPS, bitrateKbps: 3000,
      tier: `mock-rtc-${H}p${FPS}`, latencyMode: this.mode, audio: AUDIO ? { sampleRate: 48000, channels: 2 } : null,
      inputEnabled: INPUT, serverTime: nowUs(),
    });
    log(`[${this.id}] config transport=webrtc ${W}x${H}@${FPS} mode=${this.mode}`);
    const { RTCPeerConnection, MediaStream, nonstandard } = wrtc;
    const pc = (this.pc = new RTCPeerConnection({ iceServers: [] }));
    const vsrc = new nonstandard.RTCVideoSource();
    const asrc = AUDIO ? new nonstandard.RTCAudioSource() : null;
    const stream = new MediaStream();
    this.rtcTracks = [vsrc.createTrack()];
    if (asrc) this.rtcTracks.push(asrc.createTrack());
    for (const t of this.rtcTracks) pc.addTrack(t, stream);
    for (const t of pc.getTransceivers()) t.direction = 'sendonly';
    pc.onconnectionstatechange = () => log(`[${this.id}] rtc ${pc.connectionState}`);
    await pc.setLocalDescription(await pc.createOffer());
    await new Promise((r) => {
      if (pc.iceGatheringState === 'complete') return r();
      pc.onicegatheringstatechange = () => pc.iceGatheringState === 'complete' && r();
      setTimeout(r, 3000);
    });
    // Like the real server (one service address): keep UDP IPv4 host candidates only, and
    // just 127.0.0.1 when the car is this machine.
    const local = /^(::1|::ffff:127\.|127\.)/.test(this.addr || '');
    const sdp = pc.localDescription.sdp
      .split('\r\n')
      .filter((l) => !l.startsWith('a=candidate:') || (/ udp /i.test(l) && / \d+\.\d+\.\d+\.\d+ /.test(l) && (!local || l.includes(' 127.0.0.1 '))))
      .join('\r\n');
    this.json({ t: 'rtcOffer', sdp });
    log(`[${this.id}] rtcOffer sent (${sdp.split('a=candidate:').length - 1} candidates)`);

    // Media pump: raw I420 from ffmpeg (paced by us), beep PCM every 10 ms, same timeline.
    const fb = W * H * 1.5;
    // Same pattern as the ws clip, generated live (endless; frame n flashes when n % 60 < 3).
    const ff = (this.ff = spawn(FF, ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', `testsrc2=size=${W}x${H}:rate=${FPS}`, '-filter_complex', filter(), '-f', 'rawvideo', '-pix_fmt', 'yuv420p', 'pipe:1'], { stdio: ['ignore', 'pipe', 'ignore'] }));
    let pending = Buffer.alloc(0);
    const q = [];
    let made = 0;
    ff.stdout.on('data', (d) => {
      pending = pending.length ? Buffer.concat([pending, d]) : d;
      while (pending.length >= fb) {
        q.push({ n: made++, data: new Uint8ClampedArray(pending.subarray(0, fb)) });
        pending = pending.subarray(fb);
      }
      if (q.length > 4) ff.stdout.pause();
    });
    let t0 = null;
    let vi = 0;
    let ai = 0;
    const pcm = new Int16Array(960);
    this.rtcTimer = setInterval(() => {
      if (t0 == null) {
        if (q.length < 2) return;
        t0 = nowUs();
      }
      const now = nowUs();
      while (t0 + vi * FRAME_US <= now) {
        while (q.length && q[0].n < vi) q.shift(); // stay on the timeline (flash == beep)
        if (!q.length || q[0].n !== vi) break;
        vsrc.onFrame({ width: W, height: H, data: q.shift().data });
        vi++;
      }
      if (q.length < 3) ff.stdout.resume();
      while (asrc && t0 + (ai + 1) * 10000 <= now) {
        const o = (ai % 200) * 1920;
        for (let k = 0; k < 960; k++) pcm[k] = BEEP.readInt16LE(o + k * 2);
        asrc.onData({ samples: pcm, sampleRate: 48000, bitsPerSample: 16, channelCount: 2, numberOfFrames: 480 });
        ai++;
      }
    }, 4);
  }

  stopRtc() {
    clearInterval(this.rtcTimer);
    if (this.ff) this.ff.kill('SIGKILL');
    for (const t of this.rtcTracks || []) t.stop();
    if (this.pc) this.pc.close();
    this.pc = this.ff = null;
  }

  sendConfig() {
    const jp = this.clip.codec === 'jpeg';
    this.mode = this.pref === 'cinema' ? 'cinema' : 'interactive';
    this.json({
      t: 'config',
      transport: 'ws',
      codec: this.clip.codec,
      width: W,
      height: H,
      fps: FPS,
      bitrateKbps: jp ? 20000 : 3000,
      tier: jp ? 'mock-jpeg' : `mock-${H}p${FPS}`,
      latencyMode: this.mode,
      audio: AUDIO ? { sampleRate: 48000, channels: 2 } : null,
      inputEnabled: INPUT,
      serverTime: nowUs(),
    });
    log(`[${this.id}] config ${this.clip.codec} ${W}x${H}@${FPS} mode=${this.mode} audio=${AUDIO} input=${INPUT}`);
    this.t0 = nowUs() + 20000;
    this.vi = 0;
    this.ai = 0;
    this.vseq = 0;
    this.aseq = 0;
    this.waitIDR = true;
  }

  setMode(m) {
    if (m === this.mode) return;
    this.mode = m;
    this.json({ t: 'mode', latencyMode: m });
    log(`[${this.id}] mode -> ${m}`);
  }

  applyAuto() {
    this.setMode(AUDIO && Date.now() - this.lastInput > 3000 ? 'cinema' : 'interactive');
  }

  tick() {
    const now = nowUs();
    if (this.out.length) {
      let k = 0;
      while (k < this.out.length && this.out[k].at <= now) {
        const o = this.out[k++];
        if (this.ws.readyState === 1) this.ws.send(o.data, { binary: o.binary });
      }
      if (k) this.out.splice(0, k);
    }
    if (!this.clip || this.t0 == null) return;
    // Video: frame i is "captured" at t0 + i/fps and sent right away.
    while (this.t0 + this.vi * FRAME_US <= now) {
      const f = this.clip.frames[this.vi % this.clip.frames.length];
      const pts = this.t0 + this.vi * FRAME_US;
      this.vi++;
      if (this.ws.bufferedAmount > 4e6) {
        this.waitIDR = true; // congested: skip until the next IDR
        continue;
      }
      if (this.waitIDR && !f.key) continue;
      this.waitIDR = false;
      const type = this.clip.type || (this.clip.codec === 'jpeg' ? 3 : 1);
      const seq = this.vseq++;
      this.ptsOf.set(seq, pts);
      if (this.ptsOf.size > 600) this.ptsOf.delete(this.ptsOf.keys().next().value);
      this.send(Buffer.concat([header(type, f.key, seq, pts), f.data]), true);
    }
    // Audio: 10 ms packets, sent once their last sample has been "captured".
    if (AUDIO) {
      while (this.t0 + (this.ai + 1) * 10000 <= now) {
        const pts = this.t0 + this.ai * 10000;
        const o = (this.ai % 200) * 1920;
        this.ai++;
        this.send(Buffer.concat([header(4, true, this.aseq++, pts), BEEP.subarray(o, o + 1920)]), true);
      }
    }
  }

  second() {
    const a = this.acks;
    if (a.n) log(`[${this.id}] acks ${a.n}/s presented=${a.shown} decode=${(a.dec / a.n).toFixed(2)}ms net(recvAt-pts)=${(a.net / a.n).toFixed(1)}ms buffered=${this.ws.bufferedAmount}`);
    this.acks = { n: 0, shown: 0, dec: 0, net: 0 };
    if (this.pref === 'auto' && this.clip) this.applyAuto();
  }

  close(why) {
    if (!sessions.has(this)) return;
    sessions.delete(this);
    clearInterval(this.timer);
    clearInterval(this.statTimer);
    this.stopRtc();
    log(`[${this.id}] closed (${why})`);
  }
}

wss.on('connection', (ws, req) => sessions.add(new Session(ws, req.socket.remoteAddress)));

server.listen(PORT, () => {
  log(`mock Dashcast server on http://localhost:${PORT}  (ws /ws)  video=${FORCE_JPEG ? 'jpeg' : 'h264 (jpeg if no WebCodecs)'} audio=${AUDIO} input=${INPUT} mode=${modePref}${WEBRTC ? ` webrtc=${wrtc ? 'on (VP8 via @roamhq/wrtc)' : 'offer-only'}` : ''}${DELAY || JITTER ? ` delay=${DELAY}ms jitter=${JITTER}ms` : ''}`);
});

function control(s, c) {
  if (c === 'cinema' || c === 'interactive') (s.pref = c), s.setMode(c);
  else if (c === 'auto') (s.pref = 'auto'), s.applyAuto();
  else if (c === 'config' && s.pc) s.stopRtc(), s.startRtc();
  else if (c === 'config' && s.clip) s.sendConfig();
  else if (c === 'idr') s.waitIDR = true;
  else if (c === 'bye') s.json({ t: 'bye', reason: 'stopped' }), setTimeout(() => s.ws.close(), 50);
}

if (process.stdin.isTTY) {
  const keys = { c: 'cinema', i: 'interactive', a: 'auto', r: 'config', k: 'idr', b: 'bye' };
  process.stdin.setRawMode(true);
  process.stdin.on('data', (d) => {
    const c = d.toString();
    if (c === 'q' || c === '\u0003') process.exit(0);
    for (const s of sessions) control(s, keys[c]);
  });
}
