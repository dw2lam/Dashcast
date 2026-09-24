// Video decode + present pipeline. Runs inside the Worker (OffscreenCanvas) or, as a
// fallback, on the main thread with a regular canvas. Same code either way.
//
// H.264/HEVC: WebCodecs VideoDecoder, Annex B chunks, no `description`.
// JPEG: createImageBitmap(Blob); only one decode in flight, newest frame wins.
//
// interactive: present as soon as a frame is decoded.
// cinema:      queue decoded frames and present each when pts <= audio clock
//              (server µs, supplied by the main thread); drop >1 frame late.
import { createRenderer, fit, Renderer, Source } from './render';

type Out = (m: any) => void;

interface Meta {
  seq: number;
  pts: number;
  recv: number;
  t: number;
}

interface Decoded extends Meta {
  src: Source;
  w: number;
  h: number;
  dms: number;
}

export interface FrameMsg {
  k: 'f';
  ty: number;
  key: boolean;
  seq: number;
  pts: number;
  recv: number;
  buf: ArrayBuffer;
}

const HDR = 16;

export class Pipeline {
  private r: Renderer | null;
  private kind = '';
  private codec = '';
  private fd = 33333; // frame duration, µs
  private cinema = false;
  private off = 0; // server µs = performance.now()*1000 + off (this thread's clock)
  private clockA: number | null = null; // audio clock (server µs) = performance.now()*1000 + clockA
  private dec: VideoDecoder | null = null;
  private waitKey = true;
  private expect = -1;
  private metas: Meta[] = [];
  private q: Decoded[] = [];
  private jBusy = false;
  private jNext: FrameMsg | null = null;
  private gen = 0;
  private lastKeyReq = -1e9;
  private timer = 0;
  private lastPresent = 0;
  private keep: ImageBitmap | null = null;
  private fw = 0;
  private fh = 0;
  private first = false;
  private total = 0;
  private wantPx = false;
  // per-second stats
  private sT = performance.now();
  private sN = 0;
  private sDec = 0;
  private sDecN = 0;
  private sDrop = 0;
  private sLat = 0;
  private sLatN = 0;
  private sLag = 0;
  private readonly tickB = () => this.tick();

  constructor(
    private canvas: HTMLCanvasElement | OffscreenCanvas,
    pref: string,
    private delta: number, // ms: main-thread perf = this thread's perf + delta
    private out: Out,
  ) {
    this.r = createRenderer(canvas, pref);
    out(this.r ? { k: 'ready', r: this.r.kind } : { k: 'fatal', msg: 'no WebGL or 2D context' });
    setInterval(() => this.stats(), 1000);
  }

  handle(m: any): void {
    switch (m.k) {
      case 'f':
        if (m.ty === 3) this.jpeg(m);
        else if (this.kind && this.kind !== 'jpeg') this.coded(m);
        break;
      case 'cfg':
        this.config(m);
        break;
      case 'resize':
        this.resize(m.w, m.h);
        break;
      case 'clock':
        this.off = m.off + this.delta * 1000;
        this.clockA = m.a == null ? null : m.a + this.delta * 1000;
        if (this.cinema && this.q.length) this.tick();
        break;
      case 'mode':
        this.setMode(!!m.cinema);
        break;
      case 'reset':
        this.teardown();
        break;
      case 'px':
        this.wantPx = true;
        break;
    }
  }

  // ---- lifecycle -------------------------------------------------------------

  private config(m: { codec: string; fps: number }) {
    this.teardown();
    this.codec = m.codec;
    this.kind = m.codec === 'jpeg' ? 'jpeg' : /^(hvc1|hev1)/.test(m.codec) ? 'hevc' : 'h264';
    this.fd = 1e6 / (m.fps || 30);
    this.first = false;
    if (this.kind !== 'jpeg' && typeof VideoDecoder !== 'function') {
      this.out({ k: 'log', msg: 'WebCodecs unavailable for ' + m.codec });
    }
  }

  private teardown() {
    this.gen++;
    this.closeDec();
    this.metas.length = 0;
    for (const f of this.q) f.src.close();
    this.q.length = 0;
    this.jNext = null;
    this.waitKey = true;
    this.expect = -1;
    clearTimeout(this.timer);
    this.timer = 0;
  }

  private closeDec() {
    const d = this.dec;
    this.dec = null;
    if (d && d.state !== 'closed') {
      try {
        d.close();
      } catch {
        /* ignore */
      }
    }
  }

  private resize(w: number, h: number) {
    if (!this.r || (this.canvas.width === w && this.canvas.height === h)) return;
    if (this.r.resize(w, h)) return;
    if (this.keep && this.fw) this.r.draw(this.keep, this.fw, this.fh);
    else if (this.fw) this.reqKey(true); // nothing to repaint from: ask for a fresh IDR
  }

  private setMode(cinema: boolean) {
    this.cinema = cinema;
    if (!cinema && this.q.length) {
      // Leaving cinema: show the newest decoded frame now, drop the rest.
      const last = this.q.pop()!;
      for (const f of this.q) this.dropDecoded(f);
      this.q.length = 0;
      this.present(last);
    }
  }

  // ---- H.264 / HEVC ------------------------------------------------------------

  private mkDec() {
    try {
      const d: VideoDecoder = new VideoDecoder({
        output: (f) => this.onOut(f, d),
        error: (e) => this.decErr(e, d),
      });
      d.configure({ codec: this.codec, optimizeForLatency: true });
      this.dec = d;
      this.waitKey = true;
    } catch (e) {
      this.dec = null;
      this.out({ k: 'log', msg: 'decoder configure failed: ' + e });
    }
  }

  private coded(m: FrameMsg) {
    if (this.expect >= 0 && m.seq !== this.expect && !m.key) this.waitKey = true; // gap
    this.expect = m.seq + 1;
    if (!this.dec) this.mkDec();
    const d = this.dec;
    if (!d || (this.waitKey && !m.key)) {
      this.drop(m);
      this.reqKey(false);
      return;
    }
    if (!m.key && d.decodeQueueSize > 3) {
      // Decoder is falling behind: skip to the next IDR rather than build latency.
      this.waitKey = true;
      this.drop(m);
      this.reqKey(false);
      return;
    }
    this.waitKey = false;
    this.metas.push({ seq: m.seq, pts: m.pts, recv: m.recv, t: performance.now() });
    try {
      d.decode(
        new EncodedVideoChunk({ type: m.key ? 'key' : 'delta', timestamp: m.pts, data: new Uint8Array(m.buf, HDR) }),
      );
    } catch (e) {
      this.decErr(e, d);
    }
  }

  private onOut(f: VideoFrame, d: VideoDecoder) {
    if (d !== this.dec) {
      f.close();
      return;
    }
    // Output order == decode order (no B-frames); skip metas the decoder silently dropped.
    let m = this.metas.shift();
    while (m && m.pts !== f.timestamp && this.metas.length) {
      this.drop(m);
      m = this.metas.shift();
    }
    if (!m) {
      f.close();
      return;
    }
    this.decoded(f, f.displayWidth, f.displayHeight, m, performance.now() - m.t);
  }

  private decErr(e: unknown, d: VideoDecoder) {
    if (d !== this.dec) return;
    this.out({ k: 'log', msg: 'decode error: ' + e });
    this.closeDec();
    for (const m of this.metas) this.drop(m);
    this.metas.length = 0;
    this.waitKey = true;
    this.reqKey(true);
  }

  private reqKey(force: boolean) {
    const now = performance.now();
    if (!force && now - this.lastKeyReq < 1000) return;
    this.lastKeyReq = now;
    this.out({ k: 'keyframe' });
  }

  // ---- JPEG ----------------------------------------------------------------------

  private jpeg(m: FrameMsg) {
    if (this.kind !== 'jpeg') return;
    if (this.jBusy) {
      if (this.jNext) this.drop(this.jNext); // superseded while waiting
      this.jNext = m;
      return;
    }
    this.jBusy = true;
    const gen = this.gen;
    const t = performance.now();
    createImageBitmap(new Blob([new Uint8Array(m.buf, HDR) as BlobPart], { type: 'image/jpeg' })).then(
      (bm) => {
        this.jBusy = false;
        if (gen === this.gen) this.decoded(bm, bm.width, bm.height, { seq: m.seq, pts: m.pts, recv: m.recv, t }, performance.now() - t);
        else bm.close();
        this.jPump();
      },
      () => {
        this.jBusy = false;
        if (gen === this.gen) this.drop(m);
        this.jPump();
      },
    );
  }

  private jPump() {
    const n = this.jNext;
    if (n) {
      this.jNext = null;
      this.jpeg(n);
    }
  }

  // ---- presentation --------------------------------------------------------------

  private decoded(src: Source, w: number, h: number, m: Meta, dms: number) {
    this.sDec += dms;
    this.sDecN++;
    const lag = this.srvNow() - m.pts;
    if (lag > this.sLag) this.sLag = lag;
    const f: Decoded = { src, w, h, dms, seq: m.seq, pts: m.pts, recv: m.recv, t: m.t };
    if (!this.cinema) {
      this.present(f);
      return;
    }
    this.q.push(f);
    if (this.q.length > 45) this.dropDecoded(this.q.shift()!);
    this.tick();
  }

  /** cinema: present the newest frame whose pts has become audible. */
  private tick() {
    clearTimeout(this.timer);
    this.timer = 0;
    const q = this.q;
    if (!q.length) return;
    const now = performance.now();
    const clock = now * 1000 + (this.clockA == null ? this.off - 250000 : this.clockA);
    let i = -1;
    while (i + 1 < q.length && q[i + 1].pts <= clock) i++;
    if (i < 0) {
      const wait = (q[0].pts - clock) / 1000;
      if (wait < 2000) {
        this.timer = setTimeout(this.tickB, Math.max(1, wait)) as unknown as number;
        return;
      }
      i = 0; // clock is nonsense (e.g. offset not synced yet): don't hold frames hostage
    }
    for (let j = 0; j < i; j++) this.dropDecoded(q[j]);
    const f = q[i];
    q.splice(0, i + 1);
    // More than one frame late: drop, unless that would freeze the picture.
    if (clock - f.pts > this.fd && now - this.lastPresent < 200) this.dropDecoded(f);
    else this.present(f);
    if (q.length) this.tick();
  }

  private present(f: Decoded) {
    const r = this.r;
    if (r) {
      r.draw(f.src, f.w, f.h);
      if (this.wantPx) this.pixels(r, f);
    }
    this.total++;
    if (r && r.kind === '2d' && !('timestamp' in f.src)) {
      // Keep the last JPEG bitmap so a 2D resize can repaint without a round trip.
      if (this.keep) this.keep.close();
      this.keep = f.src as ImageBitmap;
    } else f.src.close();
    const now = performance.now();
    this.lastPresent = now;
    this.sN++;
    this.sLat += this.srvNow() - f.pts;
    this.sLatN++;
    this.ack(f.seq, f.recv, f.dms, true);
    if (f.w !== this.fw || f.h !== this.fh) {
      this.fw = f.w;
      this.fh = f.h;
      this.out({ k: 'size', w: f.w, h: f.h });
    }
    if (!this.first) {
      this.first = true;
      this.out({ k: 'first' });
    }
  }

  /** Debug (window.__dashcast.pixels()): sample a 3×3 grid of the content rect + the letterbox. */
  private pixels(r: Renderer, f: Decoded) {
    this.wantPx = false;
    const cw = this.canvas.width;
    const ch = this.canvas.height;
    const b = fit(cw, ch, f.w, f.h);
    const grid: number[][] = [];
    for (const fy of [1 / 6, 0.5, 5 / 6])
      for (const fx of [1 / 6, 0.5, 5 / 6]) grid.push(r.sample(Math.floor(b[0] + fx * b[2]), Math.floor(b[1] + fy * b[3])));
    const bar = b[1] > 1 ? r.sample(cw >> 1, b[1] >> 1) : b[0] > 1 ? r.sample(b[0] >> 1, ch >> 1) : null;
    this.out({ k: 'px', canvas: [cw, ch], content: b, grid, letterbox: bar, pts: f.pts, seq: f.seq });
  }

  private dropDecoded(f: Decoded) {
    f.src.close();
    this.sDrop++;
    this.ack(f.seq, f.recv, f.dms, false);
  }

  private drop(m: { seq: number; recv: number }) {
    this.sDrop++;
    this.ack(m.seq, m.recv, 0, false);
  }

  private ack(seq: number, recv: number, dms: number, presented: boolean) {
    this.out({
      k: 'ack',
      s: `{"t":"ack","seq":${seq},"recvAt":${recv},"decodeMs":${Math.round(dms * 100) / 100},"presented":${presented}}`,
    });
  }

  private srvNow() {
    return performance.now() * 1000 + this.off;
  }

  private stats() {
    const now = performance.now();
    const dt = (now - this.sT) / 1000;
    this.sT = now;
    this.out({
      k: 'stats',
      fps: Math.round((this.sN / dt) * 10) / 10,
      dec: this.sDecN ? this.sDec / this.sDecN : 0,
      drop: this.sDrop,
      q: (this.dec ? this.dec.decodeQueueSize : 0) + this.q.length + (this.jNext ? 1 : 0),
      lat: this.sLatN ? this.sLat / this.sLatN / 1000 : null,
      lag: this.sLag,
      r: this.r ? this.r.kind : '',
      dc: this.kind === 'jpeg' ? 'image' : this.kind ? 'webcodecs' : '',
      n: this.total,
    });
    this.sN = this.sDec = this.sDecN = this.sDrop = this.sLat = this.sLatN = this.sLag = 0;
  }
}
