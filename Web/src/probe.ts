// Capability probe + decode bench, run once on load before `hello`.
import { flags } from './flags';
import { H264_720P, H264_720P_CODEC, H264_1080P, H264_1080P_CODEC, JPEG_720P } from './bench-data';

export interface Caps {
  secure: boolean;
  webrtc: boolean;
  webcodecs: boolean;
  h264: { high: boolean; main: boolean; baseline: boolean };
  hevc: boolean;
  hwAccel: 'yes' | 'no' | 'unknown';
  audioWorklet: boolean;
  offscreenCanvas: boolean;
  webgl: boolean;
}

export interface Bench {
  h264_720p_decodeMs: number | null;
  h264_1080p_decodeMs: number | null;
  jpegDecodeMs: number | null;
}

export interface ProbeResult {
  caps: Caps;
  bench: Bench;
  ms: number;
}

const PROBE_CODECS = ['avc1.42E01F', 'avc1.4D401F', 'avc1.640028', 'hvc1.1.6.L123.B0'];

export function b64bytes(s: string): Uint8Array {
  const bin = atob(s);
  const u = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
  return u;
}

const mean = (a: number[]): number | null =>
  a.length ? Math.round((a.reduce((x, y) => x + y, 0) / a.length) * 100) / 100 : null;

/** Mean of the fastest 80%: one GC/GPU hiccup during page load shouldn't pick the tier. */
const robustMean = (a: number[]): number | null => mean(a.sort((x, y) => x - y).slice(0, Math.max(1, Math.ceil(a.length * 0.8))));

function timeout<T>(p: Promise<T>, ms: number, v: T): Promise<T> {
  return Promise.race([p, new Promise<T>((r) => setTimeout(() => r(v), ms))]);
}

async function supported(codec: string, hw: boolean): Promise<boolean> {
  try {
    const cfg: VideoDecoderConfig = { codec, optimizeForLatency: true };
    if (hw) cfg.hardwareAcceleration = 'prefer-hardware';
    const r = await timeout(VideoDecoder.isConfigSupported(cfg), 1500, { supported: false } as VideoDecoderSupport);
    return !!r.supported;
  } catch {
    return false;
  }
}

/** Split an Annex B elementary stream into access units at AUD NALs (type 9). */
function splitAU(u: Uint8Array): Uint8Array[] {
  const out: Uint8Array[] = [];
  let start = -1;
  for (let i = 0; i + 3 < u.length; i++) {
    if (u[i] === 0 && u[i + 1] === 0 && u[i + 2] === 1 && (u[i + 3] & 0x1f) === 9) {
      const s = i > 0 && u[i - 1] === 0 ? i - 1 : i;
      if (start >= 0) out.push(u.subarray(start, s));
      start = s;
      i += 3;
    }
  }
  if (start >= 0) out.push(u.subarray(start));
  return out;
}

/**
 * Mean per-frame decode latency (submit -> output) over the clip, excluding the first
 * (keyframe + decoder warm-up). Frames are fed one at a time, as they would be live.
 */
function benchH264(b64: string, codec: string, limit = 99): Promise<number | null> {
  const aus = splitAU(b64bytes(b64)).slice(0, limit);
  return new Promise((resolve) => {
    const sub: number[] = [];
    const times: number[] = [];
    let i = 0;
    let done = false;
    let flushing = false;
    let stall = 0;
    const fin = () => {
      if (done) return;
      done = true;
      clearTimeout(stall);
      clearTimeout(guard);
      try {
        dec.close();
      } catch {
        /* already closed */
      }
      resolve(robustMean(times.slice(1)));
    };
    const feed = () => {
      clearTimeout(stall);
      if (done) return;
      if (i >= aus.length) {
        if (!flushing) {
          flushing = true;
          dec.flush().then(fin, fin);
        }
        return;
      }
      sub[i] = performance.now();
      dec.decode(new EncodedVideoChunk({ type: i ? 'delta' : 'key', timestamp: i * 33333, data: aus[i] }));
      i++;
      // Some decoders hold a frame until more input arrives: don't wait forever.
      stall = setTimeout(feed, 150) as unknown as number;
    };
    const dec = new VideoDecoder({
      output: (f) => {
        const k = Math.round(f.timestamp / 33333);
        times.push(performance.now() - sub[k]);
        f.close();
        feed();
      },
      error: () => {
        times.length = 0;
        fin();
      },
    });
    const guard = setTimeout(fin, 5000);
    try {
      dec.configure({ codec, optimizeForLatency: true });
      feed();
    } catch {
      times.length = 0;
      fin();
    }
  });
}

async function benchJpeg(): Promise<number | null> {
  if (typeof createImageBitmap !== 'function') return null;
  try {
    const blob = new Blob([b64bytes(JPEG_720P) as BlobPart], { type: 'image/jpeg' });
    const t: number[] = [];
    for (let i = 0; i < 6; i++) {
      const s = performance.now();
      const bm = await createImageBitmap(blob);
      t.push(performance.now() - s);
      bm.close();
    }
    return robustMean(t.slice(1));
  } catch {
    return null;
  }
}

function hasWebGL(): boolean {
  try {
    const g = document.createElement('canvas').getContext('webgl');
    if (!g) return false;
    const l = g.getExtension('WEBGL_lose_context');
    if (l) l.loseContext();
    return true;
  } catch {
    return false;
  }
}

/**
 * @param renderer resolves with the video pipeline's renderer kind once it is up; the bench
 *   waits for it so worker/WebGL start-up doesn't contend with the measurement.
 */
export async function probe(renderer: Promise<string>): Promise<ProbeResult> {
  const t0 = performance.now();
  const wc =
    !flags.noWebCodecs && !flags.forceWebRTC && typeof VideoDecoder === 'function' && typeof EncodedVideoChunk === 'function';
  let hw = [false, false, false, false];
  let sw = hw;
  if (wc) {
    [hw, sw] = await Promise.all([
      Promise.all(PROBE_CODECS.map((c) => supported(c, true))),
      Promise.all(PROBE_CODECS.map((c) => supported(c, false))),
    ]);
  }
  const ok = (i: number) => hw[i] || sw[i];
  const caps: Caps = {
    secure: window.isSecureContext !== false,
    webrtc: typeof RTCPeerConnection === 'function',
    webcodecs: wc,
    h264: { high: ok(2), main: ok(1), baseline: ok(0) },
    hevc: ok(3),
    hwAccel: wc ? (hw[0] || hw[1] || hw[2] ? 'yes' : 'no') : 'unknown',
    audioWorklet: !flags.noWorklet && typeof AudioWorkletNode === 'function',
    offscreenCanvas:
      typeof OffscreenCanvas === 'function' && 'transferControlToOffscreen' in HTMLCanvasElement.prototype,
    webgl: false,
  };
  const r = await timeout(renderer, 2000, '');
  caps.webgl = r === 'webgl' || hasWebGL();
  const bench: Bench = { h264_720p_decodeMs: null, h264_1080p_decodeMs: null, jpegDecodeMs: null };
  if (!flags.noBench) {
    if (wc && (caps.h264.baseline || caps.h264.main)) {
      // Warm-up: the first decoder in a page pays one-off GPU/decoder init (measured 50-70 ms/frame).
      await benchH264(H264_720P, H264_720P_CODEC, 3);
      bench.h264_720p_decodeMs = await benchH264(H264_720P, H264_720P_CODEC);
    }
    if (wc && caps.h264.main) bench.h264_1080p_decodeMs = await benchH264(H264_1080P, H264_1080P_CODEC);
    bench.jpegDecodeMs = await benchJpeg();
  }
  return { caps, bench, ms: Math.round(performance.now() - t0) };
}
