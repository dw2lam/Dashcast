import './tesla.css';

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** Model 3/Y centre display, landscape, physical pixels. */
export const PANEL = { w: 1920, h: 1200 };

/**
 * Browser page area in panel px (research/display/NOTES.md): the windowed card below its toolbar, or
 * Theater (the youtube.com/redirect view) under its 60 px black band.
 */
export const VIEWPORT = {
  windowed: { x: 740, y: 179, w: 1180, h: 921 } as Rect,
  theater: { x: 0, y: 60, w: 1920, h: 1140 } as Rect,
};

/** Centre of the browser's tile in the photo's own dock, where the open-app bar sits. */
const DOCK_BROWSER_X = 1040;

export interface TeslaUI {
  root: HTMLDivElement;
  viewport: HTMLDivElement;
  setFull(p: number): void;
  setHint(on: boolean): void;
  /** Secure mode (https on your own domain) or Compatibility mode (plain http to 203.0.113.77). */
  setSecure(on: boolean): void;
  viewportRect(p: number): Rect;
}

const ease = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

const ICON = {
  expand: '<svg viewBox="0 0 32 32"><path d="M18 7h7v7M14 25H7v-7"/></svg>',
  back: '<svg viewBox="0 0 32 32"><path d="M26 16H7M14 8.5 6.5 16l7.5 7.5"/></svg>',
  fwd: '<svg viewBox="0 0 32 32"><path d="M6 16h19M18 8.5l7.5 7.5-7.5 7.5"/></svg>',
  warn: '<svg viewBox="0 0 24 24"><path d="M12 3.8 2.6 20h18.8z"/><path d="M12 10v4.6M12 17.4v.1"/></svg>',
  tune: '<svg viewBox="0 0 24 24"><circle cx="7.5" cy="7.5" r="2.6"/><circle cx="16.5" cy="16.5" r="2.6"/><path d="M12.5 7.5H20M4 16.5h7.5"/></svg>',
  reload: '<svg viewBox="0 0 32 32"><path d="M24.5 16a8.5 8.5 0 1 1-2.6-6.1"/><path class="dm-f" d="M25.6 5.6v7.8h-7.8z"/></svg>',
  star: '<svg viewBox="0 0 32 32"><path d="m16 4.8 3.4 7 7.6 1.1-5.5 5.4 1.3 7.6L16 22.3l-6.8 3.6 1.3-7.6L5 12.9l7.6-1.1z"/></svg>',
  marks: '<svg viewBox="0 0 32 32"><rect x="5.5" y="5.5" width="21" height="21" rx="3.5"/><path d="M13 11.5h9M13 16h9M13 20.5h9M9.6 11.5h.1M9.6 16h.1M9.6 20.5h.1"/></svg>',
  minimize: '<svg viewBox="0 0 32 32"><path d="M20 5.5V12h6.5M12 26.5V20H5.5"/></svg>',
};

export function createTesla(): TeslaUI {
  const root = document.createElement('div');
  root.className = 'dm-tsl';
  root.innerHTML = `
<div class="dm-tsl-ui"></div>
<div class="dm-tsl-card">
  <i class="dm-tsl-grab"></i>
  <span class="dm-tsl-ic dm-tsl-expand">${ICON.expand}</span>
  <span class="dm-tsl-ic dm-tsl-back">${ICON.back}</span>
  <span class="dm-tsl-ic dm-tsl-fwd">${ICON.fwd}</span>
  <div class="dm-tsl-url"><span class="dm-tsl-chip"><i>${ICON.warn}</i><span>Not secure</span></span><span class="dm-tsl-host">203.0.113.77</span><span class="dm-tsl-reload">${ICON.reload}</span></div>
  <span class="dm-tsl-ic dm-tsl-star">${ICON.star}</span>
  <span class="dm-tsl-ic dm-tsl-marks">${ICON.marks}</span>
</div>
<i class="dm-tsl-open" style="left:${DOCK_BROWSER_X - 30}px"></i>
<div class="dm-tsl-theater"></div>
<div class="dm-tsl-band">
    <span class="dm-tsl-ic dm-tsl-min">${ICON.minimize}</span>
    <span class="dm-tsl-ic dm-tsl-bback">${ICON.back}</span>
    <i class="dm-tsl-handle"></i>
    <span class="dm-tsl-hint">Swipe down to dismiss</span>
    <span class="dm-tsl-range">97%</span>
    <span class="dm-tsl-batt"><i></i></span>
</div>
<div class="dm-tsl-vp"></div>
<div class="dm-tsl-glare"></div>`;
  const q = <T extends Element>(s: string) => root.querySelector(s) as T;
  const viewport = q<HTMLDivElement>('.dm-tsl-vp');
  const theater = q<HTMLDivElement>('.dm-tsl-theater');
  const card = q<HTMLDivElement>('.dm-tsl-card');
  const open = q<HTMLElement>('.dm-tsl-open');
  const glare = q<HTMLDivElement>('.dm-tsl-glare');
  const band = q<HTMLDivElement>('.dm-tsl-band');
  const chip = q<HTMLSpanElement>('.dm-tsl-chip');
  const host = q<HTMLSpanElement>('.dm-tsl-host');
  let last = -1;

  const rect = (p: number): Rect => {
    const a = VIEWPORT.windowed;
    const b = VIEWPORT.theater;
    const t = ease(Math.min(1, Math.max(0, p)));
    return { x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), w: lerp(a.w, b.w, t), h: lerp(a.h, b.h, t) };
  };

  const ui: TeslaUI = {
    root,
    viewport,
    setFull(p) {
      if (p === last) return;
      last = p;
      const r = rect(p);
      Object.assign(viewport.style, { left: r.x + 'px', top: r.y + 'px', width: r.w + 'px', height: r.h + 'px' });
      // Theater grows out of the browser card: black from the card's top edge to the full panel.
      const t = ease(Math.min(1, Math.max(0, p)));
      const top = lerp(60, 0, t);
      const left = lerp(740, 0, t);
      const bottom = lerp(1100, 1200, t);
      Object.assign(theater.style, {
        left: left + 'px',
        top: top + 'px',
        width: 1920 - left + 'px',
        height: bottom - top + 'px',
        opacity: String(Math.min(1, p * 4)),
      });
      band.style.opacity = String(Math.min(1, Math.max(0, (p - 0.55) / 0.45)));
      // The card stays opaque until Theater's black fully covers it, so the photo's own UI never shows.
      card.style.opacity = p < 0.25 ? '1' : '0';
      open.style.opacity = String(1 - Math.min(1, p * 4));
      glare.style.clipPath = `inset(${top}px 0 ${1200 - bottom}px ${left}px)`;
    },
    setSecure(on) {
      chip.classList.toggle('dm-tsl-chip-tune', on);
      chip.innerHTML = on ? `<i>${ICON.tune}</i>` : `<i>${ICON.warn}</i><span>Not secure</span>`;
      host.textContent = on ? 'car.yourdomain.com' : '203.0.113.77';
    },
    setHint(on) {
      root.classList.toggle('dm-tsl-launch', on);
    },
    viewportRect: rect,
  };
  ui.setFull(0);
  return ui;
}
