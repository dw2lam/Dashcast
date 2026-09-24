// Audio output + A/V clock.
//
// Each s16le packet (pts = server µs of its first sample) is scheduled so that it is
// *heard* at server time pts + D, where D = the latency-mode target (60 / 250 ms), raised
// if the network/output path can't make it (adaptive floor) or, in cinema, if video needs
// longer. Packets are written back-to-back while the write head stays within ±40 ms of
// that target; beyond that (drift, mode switch) or after an underrun we re-anchor.
//
// Mapping between server time and AudioContext frames uses the clock offset plus
// getOutputTimestamp() (falls back to currentTime - outputLatency/baseLatency).
import { flags } from '../flags';
import type { Clock } from '../clock';
import { Ring } from './ring';
import { PLAYOUT_US } from '../protocol';

const SRC_RATE = 48000;
const HIST = 128; // recent (frame, pts) writes, for the audio clock lookup
const SP_SIZE = 2048;

export class AudioOut {
  kind: '' | 'worklet' | 'script' = '';
  enabled = true; // config.audio != null
  underruns = 0;
  reanchors = 0;
  videoNeedUs = 0;
  private ctx: AudioContext | null = null;
  private node: AudioWorkletNode | null = null;
  private ring: Ring | null = null;
  private out: AudioNode | null = null;
  private ready = false;
  private sr = SRC_RATE;
  private cinema = false;
  private anchored = false;
  private end = 0; // write end, context frames
  private carry = 0;
  private floor = 0; // µs
  private floorT = 0;
  private tsC = 0; // output timestamp: context seconds...
  private tsP = 0; // ...heard at this performance.now()
  private hAt = new Float64Array(HIST);
  private hPts = new Float64Array(HIST);
  private hN = new Float64Array(HIST);
  private hI = 0;

  constructor(private clock: Clock) {}

  get running(): boolean {
    return this.ready && !!this.ctx && this.ctx.state === 'running';
  }

  /** Must be called from a user gesture (autoplay policy). */
  start(): void {
    if (this.ctx) {
      this.ctx.resume();
      return;
    }
    const AC: typeof AudioContext = window.AudioContext || (window as any).webkitAudioContext;
    if (!AC) return;
    let ctx: AudioContext;
    try {
      ctx = new AC({ latencyHint: 'interactive', sampleRate: SRC_RATE });
    } catch {
      ctx = new AC();
    }
    this.ctx = ctx;
    this.sr = ctx.sampleRate;
    ctx.resume();
    let out: AudioNode = ctx.destination;
    if (flags.mute) {
      const g = ctx.createGain();
      g.gain.value = 0;
      g.connect(out);
      out = g;
    }
    this.out = out;
    if (!flags.noWorklet && ctx.audioWorklet && typeof AudioWorkletNode === 'function') {
      const url = URL.createObjectURL(new Blob([__WORKLET_SRC__], { type: 'application/javascript' }));
      ctx.audioWorklet.addModule(url).then(
        () => {
          const n = new AudioWorkletNode(ctx, 'dashcast-pcm', {
            numberOfInputs: 0,
            numberOfOutputs: 1,
            outputChannelCount: [2],
          });
          n.connect(out);
          this.node = n;
          this.kind = 'worklet';
          this.ready = true;
        },
        (e) => {
          console.warn('[dashcast] AudioWorklet failed, using ScriptProcessor:', e);
          this.startScript();
        },
      );
    } else this.startScript();
  }

  private startScript() {
    const ctx = this.ctx!;
    const sp = ctx.createScriptProcessor(SP_SIZE, 0, 2);
    const ring = new Ring();
    let next = -1;
    sp.onaudioprocess = (e) => {
      const b = e.outputBuffer;
      const l = b.getChannelData(0);
      let f0 = e.playbackTime > 0 ? Math.round(e.playbackTime * this.sr) : next;
      if (f0 < 0) f0 = Math.round(ctx.currentTime * this.sr);
      next = f0 + b.length;
      ring.read(f0, l, b.numberOfChannels > 1 ? b.getChannelData(1) : l, b.length);
    };
    sp.connect(this.out!);
    this.ring = ring;
    this.kind = 'script';
    this.ready = true;
  }

  setCinema(on: boolean): void {
    this.cinema = on;
  }

  /** Current playout delay target, µs (capture pts -> heard). */
  delayUs(): number {
    const mode = this.cinema ? PLAYOUT_US.cinema : PLAYOUT_US.interactive;
    return Math.max(mode, this.floor, this.cinema ? this.videoNeedUs : 0);
  }

  private stamp() {
    const c = this.ctx!;
    if (c.getOutputTimestamp) {
      const t = c.getOutputTimestamp();
      if (t.performanceTime! > 0 && t.contextTime! > 0) {
        this.tsC = t.contextTime!;
        this.tsP = t.performanceTime!;
        return;
      }
    }
    this.tsC = c.currentTime - ((c as any).outputLatency || c.baseLatency || 0);
    this.tsP = performance.now();
  }

  /** pcm = whole binary message (16-byte header + s16le stereo payload). */
  push(pts: number, buf: ArrayBuffer): void {
    if (!this.enabled || !this.running) return;
    const ctx = this.ctx!;
    const sr = this.sr;
    const n = (buf.byteLength - 16) >> 2;
    if (n <= 0) return;
    this.stamp();
    const off = this.clock.offsetUs;
    const tsC = this.tsC;
    const tsP = this.tsP;
    const toFrame = (s: number) => (tsC + ((s - off) / 1000 - tsP) / 1000) * sr;
    const toServer = (f: number) => ((f / sr - tsC) * 1000 + tsP) * 1000 + off;

    // Earliest frame we can still safely write (render quantum / callback lead).
    const lead = this.node ? Math.max(512, (ctx.baseLatency || 0) * sr) : 2 * SP_SIZE + 512;
    const minF = ctx.currentTime * sr + lead;

    // Adaptive floor: the smallest delay this packet could have made, +8 ms margin.
    // Rises instantly, decays at 10 ms/s.
    const now = performance.now();
    const need = toServer(minF) - pts + 8000;
    this.floor = need > this.floor ? need : Math.max(need, this.floor - (now - this.floorT) * 10);
    this.floorT = now;

    const target = toFrame(pts + this.delayUs());
    let count = n;
    if (sr !== SRC_RATE) {
      const x = (n * sr) / SRC_RATE + this.carry;
      count = Math.floor(x);
      this.carry = x - count;
    }
    let at: number;
    if (!this.anchored || this.end < minF) {
      if (this.anchored) this.underruns++;
      at = Math.round(Math.max(target, minF));
    } else {
      const err = this.end - target; // + = playing later than target
      if (Math.abs(err) > 0.04 * sr) {
        this.reanchors++;
        at = Math.round(Math.max(target, minF));
      } else {
        at = this.end;
        // Inside the ±40 ms window, steer back gently: stretch/squeeze this packet by up to
        // 2 frames (~0.4 %, ~4 ms/s, inaudible) once the error exceeds 2 ms.
        if (Math.abs(err) > 0.002 * sr) count += err > 0 ? -Math.min(2, err) : Math.min(2, -err);
        count = Math.round(count);
      }
    }
    this.anchored = true;
    this.end = at + count;
    const i = (this.hI = (this.hI + 1) % HIST);
    this.hAt[i] = at;
    this.hPts[i] = pts;
    this.hN[i] = count;
    if (this.node) this.node.port.postMessage({ at, count, buf, n }, [buf]);
    else if (this.ring) this.ring.write(at, count, new Int16Array(buf, 16, n * 2), n);
  }

  /**
   * Audio master clock: returns A such that the pts being heard right now is
   * performance.now()*1000 + A (server µs). null when nothing is playing.
   */
  clockBase(): number | null {
    if (!this.running || !this.anchored || !this.enabled) return null;
    this.stamp();
    const F = this.tsC * this.sr; // frame reaching the speaker at tsP
    if (F >= this.end) return null;
    for (let k = 0; k < HIST; k++) {
      const i = (this.hI - k + HIST) % HIST;
      const at = this.hAt[i];
      const n = this.hN[i];
      if (!n) break;
      if (F >= at && F < at + n) return this.hPts[i] + ((F - at) / this.sr) * 1e6 - this.tsP * 1000;
      if (F >= at + n) break;
    }
    return null;
  }

  bufferMs(): number | null {
    if (!this.running || !this.anchored || !this.enabled) return null;
    return Math.max(0, ((this.end - this.ctx!.currentTime * this.sr) / this.sr) * 1000);
  }

  state(): string {
    if (!this.enabled) return 'off';
    if (!this.ctx) return 'tap to start';
    if (!this.running) return this.ctx.state;
    return this.kind;
  }

  reset(): void {
    this.anchored = false;
    this.end = 0;
    this.hN.fill(0);
    if (this.node) this.node.port.postMessage({});
    if (this.ring) this.ring.reset();
  }
}
