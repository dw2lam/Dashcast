import { createTesla } from '../tesla/tesla';
import { createDesktop, type Desktop } from '../mac/desktop';
import { ASSETS } from '../assets';
import { placePhoto, quadMatrix, type Quad } from '../geometry';
import { useLive } from './useLive';
import './visuals.css';

/**
 * The office photo (Bram Van Oost, Unsplash; research/office/prep_office.py), cropped to 2700×1460. The
 * screen's outer glass and active area, edge-fitted, in that crop's px.
 */
const PHOTO = { w: 2700, h: 1460, src: [1400, 2000, 2700].map((w) => [`/demo/office-${w}.webp`, w] as const) };
const GLASS: Quad = [
  [1066.06, 164.53],
  [1601.43, 171.99],
  [1598.91, 522.22],
  [1062.49, 515.93],
];
const ACTIVE: Quad = [
  [1083.42, 180.33],
  [1584.02, 187.14],
  [1580.69, 499.02],
  [1079.45, 502.4],
];
/** The wheel and the screen: what the card keeps in frame at every size. */
const FOCUS = { x: 620, y: 60, w: 1180, h: 600 };

/** The loop, in seconds: a Safari window dragged in from the Mac's own display, left there, dragged back. */
const LOOP = 10;
const OFF = -680;
const HOME = { x: 312, y: 78 };
const GRAB = { x: 318, y: 26 };

const smooth = (t: number) => (t <= 0 ? 0 : t >= 1 ? 1 : t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

/** Window x and pointer opacity at time t of the loop. */
function at(t: number) {
  const inT = smooth((t - 0.8) / 1.7);
  const outT = smooth((t - 7.2) / 1.6);
  const x = OFF + (HOME.x - OFF) * inT - (HOME.x - OFF) * outT;
  const dragging = (t > 0.6 && t < 2.8) || (t > 7.0 && t < 9.0);
  const cursor = dragging ? 1 : 0;
  return { x, cursor };
}

/**
 * "Extend or mirror": the car's screen as a second display. A real Model 3 cabin, its screen streaming
 * the Mac's extended desktop, and a window dragged onto it from the Mac and back, every 10 s. Fills its
 * positioned parent.
 */
export function ExtendVisual() {
  const ref = useLive(() => {
    let desk: Desktop | null = null;
    let ro: ResizeObserver | null = null;
    let raf = 0;
    let t0 = performance.now();
    let held = 0;
    let cursorOn = -1;

    const pose = (t: number) => {
      if (!desk) return;
      const p = at(t);
      desk.safari.style.transform = `translate(${p.x}px, ${HOME.y}px)`;
      desk.cursor.style.transform = `translate(${p.x + GRAB.x}px, ${HOME.y + GRAB.y}px)`;
      if (p.cursor !== cursorOn) {
        cursorOn = p.cursor;
        desk.cursor.style.opacity = String(p.cursor);
      }
    };
    const tick = () => {
      pose((((performance.now() - t0) / 1000) % LOOP + LOOP) % LOOP);
      raf = requestAnimationFrame(tick);
    };

    return {
      init(el) {
        const img = el.querySelector('img') as HTMLImageElement;
        const world = el.querySelector('.dm-ev-world') as HTMLDivElement;
        const glass = el.querySelector('.dm-ev-glass') as HTMLDivElement;
        const panel = el.querySelector('.dm-ev-panel') as HTMLDivElement;
        const sheen = el.querySelector('.dm-ev-sheen') as HTMLDivElement;
        const tesla = createTesla();
        tesla.setFull(1);
        desk = createDesktop({ wallpaper: ASSETS.wallpaper, clip: ASSETS.clip });
        desk.setMode('extend');
        desk.root.style.transform = `scale(${1920 / desk.layout.w}, ${1140 / desk.layout.h})`;
        desk.player.style.display = 'none';
        desk.front(desk.safari);
        desk.cursor.style.transition = 'opacity 0.3s ease';
        tesla.viewport.appendChild(desk.root);
        panel.appendChild(tesla.root);
        glass.style.transform = quadMatrix(1072, 704, GLASS);
        panel.style.transform = quadMatrix(1920, 1200, ACTIVE);
        sheen.style.transform = quadMatrix(1920, 1200, ACTIVE);
        const layout = () => {
          const W = el.clientWidth;
          const H = el.clientHeight;
          if (!W || !H) return;
          const p = placePhoto(W, H, PHOTO.w, PHOTO.h, FOCUS, W, { x: 0.5, y: 0.46 });
          Object.assign(img.style, { width: p.w + 'px', height: p.h + 'px', transform: `translate(${p.x}px, ${p.y}px)` });
          img.sizes = Math.ceil(p.w) + 'px';
          world.style.transform = `translate(${p.x}px, ${p.y}px) scale(${p.s})`;
        };
        ro = new ResizeObserver(layout);
        ro.observe(el);
        layout();
        img.srcset = PHOTO.src.map(([u, w]) => `${u} ${w}w`).join(', ');
        img.src = PHOTO.src[0][0];
        pose(held);
      },
      play() {
        if (raf) return;
        t0 = performance.now() - held * 1000;
        raf = requestAnimationFrame(tick);
      },
      pause() {
        if (raf) held = (((performance.now() - t0) / 1000) % LOOP + LOOP) % LOOP;
        cancelAnimationFrame(raf);
        raf = 0;
      },
      still() {
        cancelAnimationFrame(raf);
        raf = 0;
        held = 5;
        pose(held);
      },
      destroy() {
        cancelAnimationFrame(raf);
        if (ro) ro.disconnect();
      },
    };
  });

  return (
    <div ref={ref} className="dm-ev" role="img" aria-label="A Tesla Model 3's centre screen working as a second display for a Mac: a window slides onto it from the Mac.">
      <img className="dm-ev-photo" alt="" decoding="async" loading="lazy" />
      <div className="dm-ev-world" aria-hidden="true">
        <div className="dm-ev-glass" />
        <div className="dm-ev-panel" />
        <div className="dm-ev-sheen" />
      </div>
    </div>
  );
}
