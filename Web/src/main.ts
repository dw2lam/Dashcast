// Dashcast in-car client: connection, clock sync, stats, UI glue.
import { flags } from './flags';
import { Clock } from './clock';
import { probe, ProbeResult } from './probe';
import { VideoOut } from './video/client';
import { AudioOut } from './audio/engine';
import { Input } from './input';
import { RtcOut } from './rtc';
import { Config, InputKind, LatencyMode, T_PCM } from './protocol';
import { HOST_MESSAGES, HostState, dismissTip, nextHost, tipWanted } from './host';

const $ = (id: string) => document.getElementById(id)!;

const clock = new Clock();
const audio = new AudioOut(clock);
let rendererUp: (kind: string) => void;
const probed = probe(new Promise<string>((r) => (rendererUp = r)));
let probeResult: ProbeResult | null = null;
probed.then((p) => {
  probeResult = p;
  console.info('[dashcast] probe', p.ms + 'ms', JSON.stringify(p.caps), JSON.stringify(p.bench));
});

let ws: WebSocket | null = null;
let cfg: Config | null = null;
let mode: LatencyMode = 'interactive';
let backoff = 500;
let everOpen = false;
let lastRx = 0;
let pingId = 0;
let pingTimer = 0;
let pingStart = 0;
let vstats: any = null;
let transport: 'ws' | 'webrtc' = 'ws';
let tapped = false;
let rtcFails = 0;
let vidW = 0;
let vidH = 0;
const rect = [0, 0, 1, 1]; // video content rect, CSS px

// ---- sending -----------------------------------------------------------------------

function sendRaw(s: string) {
  if (ws && ws.readyState === 1) ws.send(s);
}
const send = (o: object) => sendRaw(JSON.stringify(o));
const r4 = (x: number) => Math.round(x * 10000) / 10000;

let lastInput: object | null = null;
function sendInput(kind: InputKind, x: number, y: number, dx = 0, dy = 0, text: string | null = null, key: string | null = null) {
  send((lastInput = { t: 'input', kind, x: r4(x), y: r4(y), dx, dy, text, key }));
}

// ---- status pill -----------------------------------------------------------------

const pill = $('pill');
const pillText = pill.querySelector('span')!;
function status(text: string | null, cls = '') {
  if (text == null) {
    pill.className = 'pill off';
    return;
  }
  pill.className = 'pill ' + cls;
  pillText.textContent = text;
}

// ---- video -----------------------------------------------------------------------

const video = new VideoOut($('v') as HTMLCanvasElement, (m) => {
  switch (m.k) {
    case 'ack':
      sendRaw(m.s);
      break;
    case 'keyframe':
      sendRaw('{"t":"keyframe"}');
      break;
    case 'stats':
      vstats = m;
      audio.videoNeedUs = m.lag > 0 ? m.lag + 1e6 / ((cfg && cfg.fps) || 30) + 15000 : 0;
      break;
    case 'size':
      vidW = m.w;
      vidH = m.h;
      layout();
      break;
    case 'px':
      if (pxWait) pxWait(m);
      pxWait = null;
      break;
    case 'first':
      if (cfg) status(null);
      streamed();
      break;
    case 'ready':
      rendererUp(m.r);
      break;
    case 'log':
      console.warn('[dashcast]', m.msg);
      break;
  }
});

let bw = 0;
let bh = 0;
function layout() {
  const W = innerWidth;
  const H = innerHeight;
  const dpr = devicePixelRatio || 1;
  const w = Math.round(W * dpr);
  const h = Math.round(H * dpr);
  if (w !== bw || h !== bh) {
    bw = w;
    bh = h;
    video.post({ k: 'resize', w, h });
  }
  const vw = vidW || (cfg ? cfg.width : 16);
  const vh = vidH || (cfg ? cfg.height : 9);
  const s = Math.min(W / vw, H / vh);
  rect[2] = vw * s;
  rect[3] = vh * s;
  rect[0] = (W - rect[2]) / 2;
  rect[1] = (H - rect[3]) / 2;
}
// ---- WebRTC transport (HTTP mode) ------------------------------------------------------

const rv = $('rv') as HTMLVideoElement;
const rtc = new RtcOut(
  rv,
  send,
  (why) => {
    console.warn('[dashcast] WebRTC:', why);
    sendRaw('{"t":"keyframe"}');
    backoff = Math.min(5000, 1000 * Math.pow(2, rtcFails++));
    if (ws) lost(ws, "Couldn't start video");
  },
  (w, h) => {
    vidW = w;
    vidH = h;
    layout();
  },
  () => {
    rtcFails = 0;
    if (cfg) status(null);
    streamed();
  },
);

addEventListener('resize', layout);
addEventListener('orientationchange', layout);
layout();

function pushClock() {
  let a: number | null = null;
  if (mode === 'cinema') {
    a = audio.clockBase();
    if (a == null) a = clock.offsetUs - audio.delayUs(); // no audio: virtual clock at the same delay
  }
  video.post({ k: 'clock', off: clock.offsetUs, a });
}
setInterval(() => {
  if (mode === 'cinema') pushClock();
}, 100);

// ---- input -----------------------------------------------------------------------

const input = new Input($('touch'), sendInput, rect);
const kb = $('kb') as HTMLInputElement;
const kbBtn = $('bKb');
const ZW = '​'; // sentinel so Backspace on an "empty" field still fires input events
const SPECIAL = /^(Backspace|Enter|Tab|Escape|Delete|Arrow(Up|Down|Left|Right)|Home|End|PageUp|PageDown)$/;
const resetKb = () => {
  kb.value = ZW;
  try {
    kb.setSelectionRange(1, 1);
  } catch {
    /* ignore */
  }
};
kbBtn.addEventListener('mousedown', (e) => e.preventDefault()); // keep focus (and the keyboard) on #kb
kbBtn.addEventListener('click', () => {
  if (document.activeElement === kb) kb.blur();
  else {
    resetKb();
    kb.focus();
  }
});
kb.addEventListener('focus', () => kbBtn.classList.add('on'));
kb.addEventListener('blur', () => kbBtn.classList.remove('on'));
kb.addEventListener('keydown', (e) => {
  if (SPECIAL.test(e.key)) {
    e.preventDefault();
    sendInput('key', 0.5, 0.5, 0, 0, null, e.key);
  }
});
kb.addEventListener('input', (e: any) => {
  if (e.isComposing) return;
  const t: string = e.inputType || '';
  if (t.indexOf('delete') === 0) sendInput('key', 0.5, 0.5, 0, 0, null, 'Backspace');
  else if (t === 'insertLineBreak') sendInput('key', 0.5, 0.5, 0, 0, null, 'Enter');
  else {
    const v = e.data != null ? e.data : kb.value.replace(ZW, '');
    if (v) sendInput('text', 0.5, 0.5, 0, 0, v);
  }
  resetKb();
});
kb.addEventListener('compositionend', (e) => {
  if (e.data) sendInput('text', 0.5, 0.5, 0, 0, e.data);
  resetKb();
});
document.addEventListener('touchmove', (e) => e.preventDefault(), { passive: false });

// ---- connection ------------------------------------------------------------------

function wsUrl() {
  return flags.ws || (location.protocol === 'https:' ? 'wss' : 'ws') + '://' + location.host + '/ws';
}

function connect() {
  status(everOpen ? 'Reconnecting' : 'Connecting…', everOpen ? 're' : '');
  let s: WebSocket;
  try {
    s = new WebSocket(wsUrl());
  } catch {
    retry();
    return;
  }
  ws = s;
  s.binaryType = 'arraybuffer';
  s.onopen = () => {
    everOpen = true;
    lastRx = performance.now();
    clock.reset();
    pingStart = lastRx;
    ping();
    status('Waiting for Mac', 'wait');
    probed.then((p) => {
      if (ws === s && s.readyState === 1) sendHello(p);
    });
  };
  s.onmessage = (e) => {
    lastRx = performance.now();
    if (typeof e.data === 'string') text(e.data);
    else binary(e.data);
  };
  s.onclose = () => lost(s);
  s.onerror = () => {};
}

function lost(s: WebSocket, why?: string) {
  if (ws !== s) return;
  ws = null;
  s.onclose = s.onmessage = s.onopen = null;
  try {
    s.close();
  } catch {
    /* ignore */
  }
  clearTimeout(pingTimer);
  cfg = null;
  host(nextHost(hostState, { k: 'lost' }));
  input.cancel();
  input.enabled = false;
  video.post({ k: 'reset' });
  audio.reset();
  rtc.close();
  retry(why);
}

function retry(why?: string) {
  status(why || (everOpen ? 'Reconnecting' : 'Connecting…'), everOpen || why ? 're' : '');
  setTimeout(connect, backoff);
  backoff = Math.min(5000, backoff * 2);
}

function sendHello(p: ProbeResult) {
  send({
    t: 'hello',
    version: 1,
    ua: navigator.userAgent,
    viewport: { w: innerWidth, h: innerHeight, dpr: devicePixelRatio || 1 },
    caps: p.caps,
    bench: p.bench,
  });
}

function ping() {
  const now = performance.now();
  if (ws && now - lastRx > 6000) {
    lost(ws); // silent network death: don't wait for TCP to notice
    return;
  }
  send({ t: 'ping', id: ++pingId, clientTime: Math.round(now * 1000) / 1000 });
  pingTimer = window.setTimeout(ping, now - pingStart < 2000 ? 250 : 1000);
}

function text(data: string) {
  let m: any;
  try {
    m = JSON.parse(data);
  } catch {
    return;
  }
  switch (m.t) {
    case 'pong':
      if (clock.pong(m.clientTime, m.serverTime)) pushClock();
      break;
    case 'config':
      applyConfig(m);
      break;
    case 'mode':
      setMode(m.latencyMode);
      break;
    case 'bye':
      status('Waiting for Mac', 'wait');
      break;
    case 'host':
      host(nextHost(hostState, { k: 'host', state: m.state }));
      break;
    case 'rtcOffer':
      if (transport === 'webrtc') rtc.offer(m.sdp).catch((e) => console.warn('[dashcast] rtcOffer:', e));
      break;
  }
}

function applyConfig(m: Config) {
  cfg = m;
  backoff = 500;
  host(nextHost(hostState, { k: 'stream' }));
  clock.seed(m.serverTime);
  vidW = m.width;
  vidH = m.height;
  layout();
  status('Waiting for Mac', 'wait');
  transport = m.transport === 'webrtc' ? 'webrtc' : 'ws';
  const canvas = $('v');
  if (transport === 'webrtc') {
    // Media arrives over RTCPeerConnection (rtcOffer follows); the canvas pipeline idles.
    canvas.style.visibility = 'hidden';
    video.post({ k: 'reset' });
    audio.enabled = false;
    audio.reset();
    rtc.setAudible(tapped && !flags.mute && !!m.audio);
  } else {
    rtc.close();
    canvas.style.visibility = '';
    video.post({ k: 'cfg', codec: m.codec, w: m.width, h: m.height, fps: m.fps });
    audio.enabled = !!m.audio;
    if (!m.audio) audio.reset();
    else if (tapped) audio.start(); // sticky user activation from the earlier tap
  }
  input.enabled = !!m.inputEnabled;
  if (!m.inputEnabled) input.cancel();
  kbBtn.hidden = !m.inputEnabled;
  setMode(m.latencyMode);
}

function setMode(lm: string) {
  mode = lm === 'cinema' ? 'cinema' : 'interactive';
  audio.setCinema(mode === 'cinema');
  rtc.setCinema(mode === 'cinema');
  video.post({ k: 'mode', cinema: mode === 'cinema' });
  pushClock();
  paintModes();
}

function binary(buf: ArrayBuffer) {
  if (buf.byteLength < 16) return;
  const dv = new DataView(buf);
  const type = dv.getUint8(0);
  const pts = dv.getUint32(8) * 4294967296 + dv.getUint32(12);
  if (type === T_PCM) {
    audio.push(pts, buf);
    return;
  }
  if (!cfg || type < 1 || type > 3) return;
  video.post(
    { k: 'f', ty: type, key: type === 3 || (dv.getUint8(1) & 1) === 1, seq: dv.getUint32(4), pts, recv: Math.round(clock.now()) },
    buf,
  );
}

// ---- stats -----------------------------------------------------------------------

const statsEl = $('stats');
const dl = $('sDl');
const stBtn = $('bSt');
const modeBtns = Array.prototype.slice.call($('modes').querySelectorAll('button')) as HTMLButtonElement[];
let chosenMode = '';

function paintModes() {
  const sel = chosenMode || mode;
  modeBtns.forEach((b) => b.classList.toggle('on', b.getAttribute('data-m') === sel));
}
modeBtns.forEach((b) =>
  b.addEventListener('click', () => {
    chosenMode = b.getAttribute('data-m')!;
    send({ t: 'setLatencyMode', latencyMode: chosenMode });
    paintModes();
  }),
);

function toggleStats(show: boolean) {
  statsEl.hidden = !show;
  stBtn.classList.toggle('on', show);
  if (show) renderStats();
}
stBtn.addEventListener('click', () => toggleStats(!!statsEl.hidden));

const fmt = (v: number | null | undefined, unit = '', d = 1) => (v == null || isNaN(v) ? '–' : v.toFixed(d) + unit);

/** Measured audio latency (capture -> heard), ms; null when no audio is playing. */
function audioLatencyMs(): number | null {
  const a = audio.clockBase();
  return a == null ? null : (clock.now() - (performance.now() * 1000 + a)) / 1000;
}

/** Current stats in one shape for both transports. */
function cur(): any {
  const r = rtc.stats;
  if (transport === 'webrtc')
    return r
      ? { fps: r.fps, dec: r.decodeMs, drop: r.dropped, q: 0, lat: r.latencyMs, ab: r.audioBufferMs, n: r.framesDecoded, path: 'webrtc · ' + (r.decoder || r.codec || '–') }
      : { path: 'webrtc · ' + rtc.state };
  const v = vstats || {};
  return { fps: v.fps, dec: v.dec, drop: v.drop, q: v.q, lat: v.lat, ab: audio.bufferMs(), n: v.n, path: video.path + ' · ' + (v.r || '–') + ' · ' + (v.dc || '–') };
}

function renderStats() {
  const v = cur();
  const al = transport === 'ws' ? audioLatencyMs() : null;
  const av = al != null && cfg && v.lat != null ? al - v.lat : null; // + = sound lags picture
  const fps = cfg ? v.fps : null;
  const ab = v.ab;
  const rows: [string, string, string?][] = [
    ['FPS', fmt(fps, '', 1) + (cfg ? ' / ' + cfg.fps : ''), cfg && fps >= cfg.fps * 0.9 ? 'good' : ''],
    ['Decode', fmt(cfg ? v.dec : null, ' ms', 1)],
    ['Latency', fmt(cfg ? v.lat : null, ' ms', 0)],
    ['RTT', fmt(clock.rtt, ' ms', 1)],
    ['Tier', cfg ? cfg.tier : '–'],
    ['Codec', cfg ? (transport === 'webrtc' ? 'rtc ' + ((rtc.stats && rtc.stats.codec) || '') : cfg.codec) : '–'],
    ['Frame', vidW ? vidW + '×' + vidH : '–'],
    ['Audio', ab != null ? ab.toFixed(0) + ' ms · ' + (transport === 'ws' ? audio.kind : rv.muted ? 'muted' : 'rtc') : transport === 'ws' ? audio.state() : '–', audio.underruns ? 'warn' : ''],
    ['Playout', mode + ' · ' + (audio.delayUs() / 1000).toFixed(0) + ' ms'],
    ['A/V', av == null ? '–' : (av > 0 ? '+' : '') + av.toFixed(0) + ' ms'],
    ['Dropped', String(cfg ? v.drop || 0 : 0), v.drop ? 'warn' : ''],
    ['Path', v.path],
  ];
  if (probeResult) {
    const b = probeResult.bench;
    rows.push(['Bench', fmt(b.h264_720p_decodeMs, '', 1) + ' / ' + fmt(b.h264_1080p_decodeMs, '', 1) + ' / ' + fmt(b.jpegDecodeMs, '', 1)]);
  }
  dl.innerHTML = rows.map((r) => '<dt>' + r[0] + '</dt><dd class="' + (r[2] || '') + '">' + r[1] + '</dd>').join('');
}

function sendStats() {
  const v = cur();
  send({
    t: 'stats',
    fps: v.fps || 0,
    decodeMs: v.dec ? Math.round(v.dec * 100) / 100 : 0,
    dropped: v.drop || 0,
    queue: v.q || 0,
    latencyMs: v.lat != null ? Math.round(v.lat) : null,
    audioBufferMs: v.ab != null ? Math.round(v.ab) : null,
  });
  if (!statsEl.hidden) renderStats();
}

setInterval(() => {
  if (!cfg) {
    if (!statsEl.hidden) renderStats();
  } else if (transport === 'webrtc' && rtc.active)
    rtc.poll(clock.rtt).then(sendStats, (e) => console.warn('[dashcast] getStats:', e));
  else sendStats();
}, 1000);

// ---- the Mac is locked / asleep (PROTOCOL.md `host`) -------------------------------

const hostEl = $('host');
const hostIcons: Record<string, HTMLElement> = { lock: $('iLock'), display: $('iDisplay'), moon: $('iMoon') };
let hostState: HostState = 'active';

function host(next: HostState) {
  if (next === hostState) return;
  hostState = next;
  document.body.classList.toggle('paused', next !== 'active');
  if (next === 'active') {
    hostEl.hidden = true;
    return;
  }
  const msg = HOST_MESSAGES[next];
  $('hostTitle').textContent = msg.title;
  $('hostBody').textContent = msg.body;
  Object.keys(hostIcons).forEach((k) => (hostIcons[k].style.display = k === msg.icon ? '' : 'none'));
  hostEl.hidden = false;
}

// ---- one-time bookmark tip -------------------------------------------------------

const tip = $('tip');
let store: Storage | null = null;
try {
  store = window.localStorage;
} catch {
  /* storage blocked */
}
let tipOffered = false;

/** First picture on screen: offer the bookmark tip once (until it's dismissed on this car). */
function streamed() {
  if (tipOffered || !tipWanted(store)) return;
  tipOffered = true;
  setTimeout(() => (tip.hidden = false), 1500);
}
$('tipX').addEventListener('click', () => {
  tip.hidden = true;
  dismissTip(store);
});

// ---- tap to start / fullscreen ---------------------------------------------------

const tap = $('tap');
tap.addEventListener('click', () => {
  tapped = true;
  if (transport === 'webrtc') rtc.setAudible(!flags.mute && !!(cfg && cfg.audio));
  // In HTTP mode (not secure) media will most likely come over WebRTC: don't spin up a
  // ScriptProcessor for nothing; applyConfig starts it later if the ws transport is used.
  else if (cfg || window.isSecureContext) audio.start();
  tap.classList.add('off');
  setTimeout(() => (tap.hidden = true), 450);
});

const toast = $('toast');
let toastTimer = 0;
function fsHint() {
  const theater = 'https://www.youtube.com/redirect?q=' + encodeURIComponent(location.href);
  toast.innerHTML =
    "<b>Fullscreen isn't available here</b><span>This browser blocks the Fullscreen API. In a Tesla, pages opened through youtube.com/redirect load in Theater mode.</span><br><a href=\"" +
    theater +
    '">Open in Theater mode</a>';
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => (toast.hidden = true), 9000);
}
toast.addEventListener('click', (e) => {
  if ((e.target as HTMLElement).tagName !== 'A') toast.hidden = true;
});
$('bFs').addEventListener('click', () => {
  const d: any = document;
  const el: any = document.documentElement;
  if (d.fullscreenElement || d.webkitFullscreenElement) {
    (d.exitFullscreen || d.webkitExitFullscreen).call(d);
    return;
  }
  const req = el.requestFullscreen || el.webkitRequestFullscreen;
  if (!req || d.fullscreenEnabled === false) {
    fsHint();
    return;
  }
  try {
    const p = req.call(el);
    if (p && p.catch) p.catch(fsHint);
  } catch {
    fsHint();
  }
});

// Debug/test handle: window.__dashcast.state() (plain JSON), .pixels() samples the next
// presented frame in the renderer (3×3 grid of the content rect + a letterbox pixel).
let pxWait: ((m: any) => void) | null = null;
(window as any).__dashcast = {
  state: () => {
    const v = cur();
    return {
      status: pill.className.indexOf('off') >= 0 ? 'streaming' : pillText.textContent,
      transport,
      tier: cfg && cfg.tier,
      host: hostState,
      tip: !tip.hidden,
      codec: cfg && cfg.codec,
      mode,
      fps: v.fps,
      decodeMs: v.dec,
      latencyMs: v.lat,
      audioBufferMs: v.ab,
      dropped: v.drop,
      framesPresented: v.n,
      path: v.path,
      frame: [vidW, vidH],
      canvas: [bw, bh],
      viewport: [innerWidth, innerHeight, devicePixelRatio],
      contentRect: rect.map((x) => Math.round(x * 10) / 10),
      rttMs: clock.rtt,
      audio: { kind: audio.kind, state: audio.state(), bufferMs: audio.bufferMs(), latencyMs: audioLatencyMs(), targetMs: audio.delayUs() / 1000, underruns: audio.underruns, reanchors: audio.reanchors, muted: flags.mute },
      rtc: { state: rtc.state, stats: rtc.stats, video: [rv.videoWidth, rv.videoHeight], paused: rv.paused, muted: rv.muted, hidden: rv.hidden },
      lastInput,
      probe: probeResult,
    };
  },
  pixels: () =>
    new Promise((r) => {
      if (transport === 'webrtc') {
        // <video> path: sample a 3×3 grid of the current frame through a small 2D canvas.
        const c = document.createElement('canvas');
        c.width = 96;
        c.height = 54;
        const x = c.getContext('2d', { willReadFrequently: true } as any) as CanvasRenderingContext2D;
        x.drawImage(rv, 0, 0, 96, 54);
        const grid: number[][] = [];
        for (const fy of [9, 27, 45]) for (const fx of [16, 48, 80]) grid.push([].slice.call(x.getImageData(fx, fy, 1, 1).data, 0, 3));
        r({ k: 'px', video: [rv.videoWidth, rv.videoHeight], grid, time: rv.currentTime });
        return;
      }
      pxWait = r;
      video.post({ k: 'px' });
      setTimeout(() => r(null), 3000);
    }),
};

if (flags.stats) toggleStats(true);
paintModes();
connect();
