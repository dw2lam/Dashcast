// Main-thread handle on the video pipeline: a Worker + OffscreenCanvas when available,
// otherwise the same Pipeline running on the main thread.
import { flags } from '../flags';
import type { Pipeline } from './pipeline';

export class VideoOut {
  path = '';
  private w: Worker | null = null;
  private p: Pipeline | null = null;
  private ready = false;
  private last: Record<string, any> = {};

  constructor(
    private canvas: HTMLCanvasElement,
    private on: (m: any) => void,
  ) {
    const c = canvas;
    if (!flags.noWorker && typeof Worker === 'function' && typeof OffscreenCanvas === 'function' && c.transferControlToOffscreen) {
      try {
        const w = new Worker(URL.createObjectURL(new Blob([__WORKER_SRC__], { type: 'application/javascript' })));
        const off = c.transferControlToOffscreen();
        w.onmessage = (e) => this.msg(e.data);
        w.onerror = (e) => {
          if (!this.ready) {
            e.preventDefault();
            this.fallback('worker failed to start');
          }
        };
        w.postMessage({ k: 'init', canvas: off, r: flags.renderer, t0: performance.timeOrigin, now: performance.now() }, [off]);
        this.w = w;
        this.path = 'worker';
        return;
      } catch (e) {
        console.warn('[dashcast] worker unavailable:', e);
      }
    }
    this.main();
  }

  private main() {
    const w = window as any;
    // eslint-disable-next-line no-new-func
    if (!w.__dashcastPipeline) new Function(__WORKER_SRC__)();
    this.path = 'main';
    this.p = new w.__dashcastPipeline(this.canvas, flags.renderer, 0, (m: any) => this.msg(m)) as Pipeline;
  }

  private msg(m: any) {
    if (m.k === 'ready') this.ready = true;
    if (m.k === 'fatal') this.fallback(m.msg);
    else this.on(m);
  }

  /** The worker couldn't render: swap in a fresh canvas and run on the main thread. */
  private fallback(why: string) {
    console.warn('[dashcast] video worker fallback:', why);
    if (!this.w) return;
    this.w.terminate();
    this.w = null;
    const c = document.createElement('canvas');
    c.id = this.canvas.id;
    this.canvas.replaceWith(c);
    this.canvas = c;
    this.main();
    for (const k of ['resize', 'clock', 'mode', 'cfg']) if (this.last[k]) this.p!.handle(this.last[k]);
    this.on({ k: 'keyframe' });
  }

  post(m: any, buf?: ArrayBuffer): void {
    if (m.k !== 'f') this.last[m.k] = m;
    if (buf) m.buf = buf;
    if (this.w) this.w.postMessage(m, buf ? [buf] : []);
    else if (this.p) this.p.handle(m);
  }
}
