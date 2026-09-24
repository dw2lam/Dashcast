import type { StatRow } from './client';

export type TierId = 'mcu2' | 'mcu3';
export type Transport = 'ws' | 'webrtc';
export type Playout = 'interactive' | 'cinema';

/**
 * What the real tiers send in `config` (Sources/DashcastContracts/Contracts.swift). The demo shows
 * MCU2 in Compatibility mode (http://203.0.113.77 → WebRTC, constrained-baseline H.264 at the mcu2
 * tier) and MCU3 in Secure mode (https → WebCodecs, HEVC), since HEVC needs WebCodecs.
 */
export const TIERS = {
  mcu2: { id: 'mcu2', codec: 'avc1.42E01F', budget: [1280, 720], fps: 30, transport: 'webrtc' as Transport },
  mcu3: { id: 'mcu3-hevc', codec: 'hvc1.1.6.L123.B0', budget: [1920, 1200], fps: 60, transport: 'ws' as Transport },
} as const;

const mbs = (w: number, h: number) => Math.ceil(w / 16) * Math.ceil(h / 16);

/**
 * TierSelector.encodeSize, ported: the tier's pixel budget fitted to the viewport's aspect, never
 * larger than its device pixels, even, and within the tier's macroblock count.
 */
export function encodeSize(budget: readonly [number, number], vw: number, vh: number, dpr: number): [number, number] {
  const dw = vw * dpr;
  const dh = vh * dpr;
  const aspect = dw / dh;
  const scale = Math.min(1, Math.sqrt((budget[0] * budget[1]) / (dw * dh)));
  const even = (v: number) => Math.max(2, Math.floor(v) & ~1);
  let w = even(dw * scale);
  let h = even(dh * scale);
  const max = mbs(budget[0], budget[1]);
  while (mbs(w, h) > max && w > 16 && h > 16) {
    if (aspect >= 1) {
      w -= 2;
      h = even(w / aspect);
    } else {
      h -= 2;
      w = even(h * aspect);
    }
  }
  return [w, h];
}

/**
 * Means from local runs (Mac → Chrome on the same Mac, never a car). WebCodecs: the app's HEVC tier
 * (57 fps, 8.5 ms end to end; cinema A/V ≈ 2 ms) and the real client's overlay against the mock
 * server (decode, RTT, audio buffer). WebRTC: the app's Chrome interop test (29.9 fps, 1.45 ms decode,
 * 31 ms video and 30 ms audio jitter buffer; with a 250 ms jitterBufferTarget in cinema).
 */
const LOCAL = {
  ws: { fps: 57.1, dec: 1.1, lat: 8.5, cinemaLat: 256, buf: 52, cinemaBuf: 226, av: 2 },
  webrtc: { fps: 29.9, dec: 1.45, lat: 31, cinemaLat: 252, buf: 30, cinemaBuf: 248, av: 0 },
  rtt: 0.3,
};

const fmt = (v: number | null, unit = '', d = 1) => (v == null || isNaN(v) ? '–' : v.toFixed(d) + unit);

/** Deterministic wobble so the overlay ticks once a second like the real one. */
function wob(seed: number, amp: number) {
  const x = Math.sin(seed * 12.9898 + amp * 78.233) * 43758.5453;
  return (x - Math.floor(x) - 0.5) * 2 * amp;
}

/**
 * The real client's overlay rows (Web/src/main.ts renderStats), minus the probe's Bench row, in the
 * shape each transport gives them: over WebRTC the Codec, Audio and Path rows come from getStats
 * (Chrome hides decoderImplementation, so Path falls back to the codec), and there's no A/V row value.
 */
export function statsRows(o: {
  tier: TierId;
  frame: [number, number];
  playout: Playout;
  streaming: boolean;
  tapped: boolean;
  audioPlaying: boolean;
  tick: number;
}): StatRow[] {
  const t = TIERS[o.tier];
  const rtc = t.transport === 'webrtc';
  const m = LOCAL[t.transport];
  const on = o.streaming;
  const cinema = o.playout === 'cinema';
  const fps = on ? Math.min(t.fps, m.fps + wob(o.tick, rtc ? 0.3 : 1.9)) : null;
  const dec = on ? m.dec + wob(o.tick + 3, 0.25) : null;
  const lat = on ? (cinema ? m.cinemaLat + wob(o.tick + 5, 6) : m.lat + wob(o.tick + 5, rtc ? 3 : 0.6)) : null;
  const buf = cinema ? m.cinemaBuf + wob(o.tick + 7, 12) : m.buf + wob(o.tick + 7, 5);
  const av = !rtc && on && o.tapped && o.audioPlaying && cinema ? m.av + wob(o.tick + 9, 3) : null;
  const audio = !on ? 'tap to start' : rtc ? buf.toFixed(0) + ' ms · ' + (o.tapped ? 'rtc' : 'muted') : !o.tapped ? 'tap to start' : buf.toFixed(0) + ' ms · worklet';
  return [
    ['FPS', fmt(fps, '', 1) + (on ? ' / ' + t.fps : ''), on && fps! >= t.fps * 0.9 ? 'dm-good' : ''],
    ['Decode', fmt(dec, ' ms', 1)],
    ['Latency', fmt(lat, ' ms', 0)],
    ['RTT', fmt(LOCAL.rtt + wob(o.tick + 11, 0.1), ' ms', 1)],
    ['Tier', on ? t.id : '–'],
    ['Codec', on ? (rtc ? 'rtc H264' : t.codec) : '–'],
    ['Frame', on ? o.frame[0] + '×' + o.frame[1] : '–'],
    ['Audio', audio],
    ['Playout', o.playout + ' · ' + (cinema ? 250 : 60) + ' ms'],
    ['A/V', av == null ? '–' : (av > 0 ? '+' : '') + av.toFixed(0) + ' ms'],
    ['Dropped', '0'],
    ['Path', on ? (rtc ? 'webrtc · H264' : 'worker · webgl · webcodecs') : 'worker · – · –'],
  ];
}
