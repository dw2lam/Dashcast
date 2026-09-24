// Touch → remote pointer. Coordinates are normalised over the video content rect
// (letterbox excluded).
//
// One finger: nothing is sent until the gesture is known —
//   moved > 10 px      -> down (at the start point), move… (one per animation frame), up
//   released quickly   -> down + up (a click)
//   held 500 ms still  -> rightClick
// Two fingers: scroll with WheelEvent semantics (positive dy = scroll down), so fingers moving up scroll down.
// A mouse (desktop testing) maps directly: down/move/up, right button, wheel.
import type { InputKind } from './protocol';

export type SendInput = (kind: InputKind, x: number, y: number, dx: number, dy: number) => void;

const SLOP = 10;
const HOLD_MS = 500;
const EDGE = 12; // px of letterbox still accepted as a touch on the frame edge

const enum S {
  Idle,
  Pending,
  Drag,
  Scroll,
  Held,
  Ignore,
}

export class Input {
  enabled = false;
  private pts = new Map<number, { x: number; y: number }>();
  private st = S.Idle;
  private sx = 0;
  private sy = 0;
  private lx = 0;
  private ly = 0;
  private cx = 0;
  private cy = 0;
  private adx = 0;
  private ady = 0;
  private hold = 0;
  private raf = 0;
  private to = 0;
  private dirty = false;

  constructor(
    el: HTMLElement,
    private send: SendInput,
    private rect: number[], // [x, y, w, h] CSS px, kept current by the caller
  ) {
    el.addEventListener('pointerdown', (e) => this.down(e, el));
    el.addEventListener('pointermove', (e) => this.move(e));
    el.addEventListener('pointerup', (e) => this.up(e, false));
    el.addEventListener('pointercancel', (e) => this.up(e, true));
    el.addEventListener('contextmenu', (e) => e.preventDefault());
    el.addEventListener('wheel', (e) => this.wheel(e), { passive: false });
  }

  private emit(kind: InputKind, x: number, y: number, dx = 0, dy = 0) {
    const r = this.rect;
    const nx = Math.min(1, Math.max(0, (x - r[0]) / r[2]));
    const ny = Math.min(1, Math.max(0, (y - r[1]) / r[3]));
    this.send(kind, nx, ny, dx, dy);
  }

  private inside(x: number, y: number) {
    const r = this.rect;
    return x >= r[0] - EDGE && x <= r[0] + r[2] + EDGE && y >= r[1] - EDGE && y <= r[1] + r[3] + EDGE;
  }

  private down(e: PointerEvent, el: HTMLElement) {
    e.preventDefault();
    if (!this.enabled) return;
    try {
      el.setPointerCapture(e.pointerId);
    } catch {
      /* ignore */
    }
    this.pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
    const x = e.clientX;
    const y = e.clientY;
    if (e.pointerType === 'mouse') {
      if (!this.inside(x, y)) this.st = S.Ignore;
      else if (e.button === 2) {
        this.st = S.Held;
        this.emit('rightClick', x, y);
      } else {
        this.st = S.Drag;
        this.lx = x;
        this.ly = y;
        this.emit('down', x, y);
      }
      return;
    }
    const n = this.pts.size;
    if (n === 1) {
      if (!this.inside(x, y)) {
        this.st = S.Ignore;
        return;
      }
      this.st = S.Pending;
      this.sx = this.lx = x;
      this.sy = this.ly = y;
      this.hold = window.setTimeout(() => {
        if (this.st === S.Pending) {
          this.st = S.Held;
          this.emit('rightClick', this.sx, this.sy);
        }
      }, HOLD_MS);
    } else if (n === 2) {
      clearTimeout(this.hold);
      if (this.st === S.Drag) {
        this.flush();
        this.emit('up', this.lx, this.ly);
      }
      if (this.st === S.Pending || this.st === S.Drag) {
        this.st = S.Scroll;
        this.centroid();
        this.adx = this.ady = 0;
      }
    }
  }

  private centroid() {
    let x = 0;
    let y = 0;
    let n = 0;
    this.pts.forEach((p) => {
      if (n < 2) {
        x += p.x;
        y += p.y;
        n++;
      }
    });
    if (n) {
      this.cx = x / n;
      this.cy = y / n;
    }
  }

  private move(e: PointerEvent) {
    const p = this.pts.get(e.pointerId);
    if (!p) return;
    p.x = e.clientX;
    p.y = e.clientY;
    if (this.st === S.Pending) {
      if (Math.abs(p.x - this.sx) > SLOP || Math.abs(p.y - this.sy) > SLOP) {
        clearTimeout(this.hold);
        this.st = S.Drag;
        this.emit('down', this.sx, this.sy);
        this.lx = p.x;
        this.ly = p.y;
        this.sched();
      }
    } else if (this.st === S.Drag) {
      this.lx = p.x;
      this.ly = p.y;
      this.sched();
    } else if (this.st === S.Scroll) {
      const ox = this.cx;
      const oy = this.cy;
      this.centroid();
      this.adx += this.cx - ox;
      this.ady += this.cy - oy;
      this.sched();
    }
  }

  private sched() {
    this.dirty = true;
    if (this.raf) return;
    // One move per animation frame; the timeout covers a page whose rAF is paused.
    const go = () => {
      cancelAnimationFrame(this.raf);
      clearTimeout(this.to);
      this.raf = 0;
      this.flush();
    };
    this.raf = requestAnimationFrame(go);
    this.to = window.setTimeout(go, 50);
  }

  private flush() {
    if (!this.dirty) return;
    this.dirty = false;
    if (this.st === S.Drag) this.emit('move', this.lx, this.ly);
    else if (this.st === S.Scroll && (this.adx || this.ady)) {
      this.emit('scroll', this.cx, this.cy, -Math.round(this.adx * 10) / 10, -Math.round(this.ady * 10) / 10);
      this.adx = this.ady = 0;
    }
  }

  private up(e: PointerEvent, cancel: boolean) {
    const p = this.pts.get(e.pointerId);
    if (!p) return;
    this.pts.delete(e.pointerId);
    if (this.st === S.Pending) {
      clearTimeout(this.hold);
      if (!cancel) {
        this.emit('down', this.sx, this.sy);
        this.emit('up', this.sx, this.sy);
      }
      this.st = S.Ignore;
    } else if (this.st === S.Drag) {
      this.lx = p.x;
      this.ly = p.y;
      this.flush();
      this.emit('up', this.lx, this.ly);
      this.st = S.Ignore;
    } else if (this.st === S.Scroll) {
      this.flush();
      this.centroid(); // re-base on the remaining finger; no jump
    }
    if (!this.pts.size) this.st = S.Idle;
  }

  private wheel(e: WheelEvent) {
    e.preventDefault();
    if (!this.enabled || !this.inside(e.clientX, e.clientY)) return;
    const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? innerHeight : 1;
    this.emit('scroll', e.clientX, e.clientY, e.deltaX * k, e.deltaY * k);
  }

  /** Release anything held (e.g. input disabled mid-drag). */
  cancel(): void {
    clearTimeout(this.hold);
    if (this.st === S.Drag) this.emit('up', this.lx, this.ly);
    this.pts.clear();
    this.st = S.Idle;
  }
}
