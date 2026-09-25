import { mapQuad, placePhoto, quadMatrix, quadUV, type Quad } from './geometry';
import { PHOTO } from './photo';
import { fitSlab } from './visuals/slab';
import { PANEL } from './tesla/tesla';
import type { DemoScreen } from './screen';

export type Framing = 'hero' | 'section' | 'screen';

/** Hero chrome the screen keeps clear of: title + CTAs above, the stats row below (px). */
export const HERO_TOP = 260;
export const HERO_BOTTOM = 110;

/** Screen width (px) and where its centre sits (fractions of the host) for a host size. */
function frame(kind: Framing, w: number, h: number) {
  if (kind === 'hero') {
    // The hero's title and CTAs cover ~260 px at the top and its stats ~110 px at the bottom:
    // the screen fills most of the band between them, centred in it.
    const frac = w < 600 ? 0.9 : w < 900 ? 0.62 : w < 1300 ? 0.42 : 0.36;
    const band = Math.max(160, h - HERO_TOP - HERO_BOTTOM);
    const aspect = PHOTO.focus.w / PHOTO.focus.h;
    return { targetW: Math.min(w * frac, band * 0.8 * aspect), bias: { x: 0.5, y: (HERO_TOP + (h - HERO_BOTTOM)) / 2 / h } };
  }
  // Section: as wide as the width allows, but always short enough to leave the whole screen (and a
  // little dash below it) in view, so a short, wide stage frames by height.
  const frac = w < 600 ? 0.94 : w < 900 ? 0.76 : 0.6;
  return { targetW: Math.min(w * frac, h * 0.78 * (PHOTO.focus.w / PHOTO.focus.h)), bias: { x: 0.5, y: 0.5 } };
}

interface StageOptions {
  framing: Framing;
  eager: boolean;
}

const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

/**
 * The cabin photo with the live panel mapped onto its screen (view 0), or the panel straight on
 * (view 1). Everything is recomputed from the host's rendered size, so the panel stays locked to the
 * photo's glass at any size or crop. Between views the four corners are interpolated.
 */
export class Stage {
  readonly el: HTMLDivElement;
  readonly img: HTMLImageElement;
  private glass: HTMLDivElement;
  private bezel: HTMLDivElement;
  private glow: HTMLDivElement;
  private ro: ResizeObserver;
  private cabinQuad: Quad | null = null;
  private flatQuad: Quad | null = null;
  private listeners: (() => void)[] = [];
  private fadeTimer = 0;
  view = 0;

  constructor(
    private host: HTMLElement,
    private opts: StageOptions,
  ) {
    this.el = document.createElement('div');
    this.el.className = 'dm-stg';
    this.img = document.createElement('img');
    this.img.className = 'dm-stg-photo';
    this.img.alt = '';
    this.img.decoding = 'async';
    this.img.loading = opts.eager ? 'eager' : 'lazy';
    if (opts.eager) this.img.setAttribute('fetchpriority', 'high');
    this.bezel = document.createElement('div');
    this.bezel.className = 'dm-stg-bezel';
    this.glass = document.createElement('div');
    this.glass.className = 'dm-stg-glass';
    this.glow = document.createElement('div');
    this.glow.className = 'dm-stg-glow';
    const flat = opts.framing === 'screen';
    if (flat) {
      this.view = 1;
      this.el.classList.add('dm-stg-flat');
      this.el.append(this.bezel, this.glass);
    } else this.el.append(this.img, this.glow, this.bezel, this.glass);
    host.appendChild(this.el);
    this.ro = new ResizeObserver(() => this.layout());
    this.ro.observe(host);
    this.layout();
    if (flat) return;
    // srcset only once `sizes` is known, so the first request is already the right width.
    this.img.srcset = Object.entries(PHOTO.src)
      .map(([w, u]) => u + ' ' + w + 'w')
      .join(', ');
    this.img.src = PHOTO.src[1600];
  }

  /** Swaps what's on the screen behind a brief, calm dip to the black of the glass. */
  fade(change: () => void) {
    clearTimeout(this.fadeTimer);
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      change();
      return;
    }
    const g = this.glass;
    g.style.transition = 'opacity 0.22s ease-in';
    g.style.opacity = '0';
    this.fadeTimer = window.setTimeout(() => {
      change();
      g.style.transition = 'opacity 0.42s ease-out';
      g.style.opacity = '1';
    }, 240);
  }

  attach(screen: DemoScreen) {
    this.glass.appendChild(screen.el);
    this.layout();
  }

  onLayout(fn: () => void) {
    this.listeners.push(fn);
  }

  setView(t: number) {
    this.view = t;
    this.apply();
  }

  layout() {
    const cw = this.host.clientWidth;
    const ch = this.host.clientHeight;
    if (!cw || !ch) return;
    if (this.opts.framing === 'screen') {
      // Just the screen: the slab (panel + bezel) filling the host.
      const f = fitSlab(cw, ch, 0);
      this.flatQuad = this.cabinQuad = [
        [f.x, f.y],
        [f.x + f.w, f.y],
        [f.x + f.w, f.y + f.h],
        [f.x, f.y + f.h],
      ];
      this.apply();
      return;
    }
    const f = frame(this.opts.framing, cw, ch);
    const p = placePhoto(cw, ch, PHOTO.width, PHOTO.height, PHOTO.focus, f.targetW, f.bias);
    Object.assign(this.img.style, { width: p.w + 'px', height: p.h + 'px', transform: `translate(${p.x}px, ${p.y}px)` });
    this.img.sizes = Math.ceil(p.w) + 'px';
    this.cabinQuad = mapQuad(PHOTO.quad, p);
    // Straight on: the 16:10 panel fitted into the host with room for its bezel.
    const pad = Math.max(16, Math.min(cw, ch) * 0.07);
    const k = Math.min((cw - pad * 2) / PANEL.w, (ch - pad * 2) / PANEL.h);
    const w = PANEL.w * k;
    const h = PANEL.h * k;
    const x = (cw - w) / 2;
    const y = (ch - h) / 2;
    this.flatQuad = [
      [x, y],
      [x + w, y],
      [x + w, y + h],
      [x, y + h],
    ];
    this.apply();
  }

  /** Current quad of the panel in host px. */
  quad(): Quad | null {
    const a = this.cabinQuad;
    const b = this.flatQuad;
    if (!a || !b) return null;
    const t = this.view;
    return a.map((p, i) => [lerp(p[0], b[i][0], t), lerp(p[1], b[i][1], t)]) as Quad;
  }

  private apply() {
    const q = this.quad();
    if (!q) return;
    const t = this.view;
    const m = quadMatrix(PANEL.w, PANEL.h, q);
    this.glass.style.transform = m;
    this.bezel.style.transform = m;
    this.glow.style.transform = m;
    this.el.style.setProperty('--view', String(t));
    this.img.style.opacity = String(1 - t);
    this.bezel.style.opacity = String(t);
    this.glow.style.opacity = String(1 - t);
    this.listeners.forEach((fn) => fn());
  }

  /** Host px → panel px, or null when the point is off the glass. */
  toPanel(x: number, y: number): [number, number] | null {
    const q = this.quad();
    if (!q) return null;
    const [u, v] = quadUV(q, x, y);
    if (u < -0.01 || u > 1.01 || v < -0.01 || v > 1.01) return null;
    return [u * PANEL.w, v * PANEL.h];
  }

  destroy() {
    clearTimeout(this.fadeTimer);
    this.ro.disconnect();
    this.listeners = [];
    this.el.remove();
  }
}
