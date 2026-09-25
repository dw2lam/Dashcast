import { createTesla } from '../tesla/tesla';
import { createDesktop, type Desktop } from '../mac/desktop';
import { ASSETS } from '../assets';
import { useLive } from './useLive';
import './visuals.css';

/** Panel rows a strip shows (Theater band, menu bar, the dragged window), and the bezel in view. */
const ROWS = 430;
const BEZEL = 22;
/** The drag: across 360 pt and back every 3.2 s, eased like a hand. */
const PERIOD = 3.2;
const SPAN = 360;
const X0 = 36;
const Y0 = 62;

interface Strip {
  el: HTMLDivElement;
  panel: HTMLDivElement;
  desk: Desktop;
  fps: number;
  frame: number;
}

const dragX = (t: number) => X0 + (SPAN * (1 - Math.cos((2 * Math.PI * t) / PERIOD))) / 2;

/**
 * "Built for MCU2 and MCU3": the same window drag on the car's screen, twice, close up. The top strip
 * is MCU2's stream (720p30: a 1242×736 frame upscaled, new picture every 1/30 s), the bottom MCU3's
 * (1920×1138 at 60 fps). Fills its positioned parent.
 */
export function McuVisual() {
  const ref = useLive(() => {
    const strips: Strip[] = [];
    let ro: ResizeObserver | null = null;
    let raf = 0;
    let t0 = performance.now();
    let held = 0;

    const pose = (s: Strip, t: number) => {
      const x = dragX(t);
      s.desk.player.style.transform = `translate(${x}px, ${Y0}px)`;
      s.desk.cursor.style.transform = `translate(${x + 205}px, ${Y0 + 16}px)`;
    };
    const tick = () => {
      const t = (performance.now() - t0) / 1000;
      for (const s of strips) {
        const f = Math.floor(t * s.fps);
        if (s.fps >= 60 || f !== s.frame) {
          s.frame = f;
          pose(s, s.fps >= 60 ? t : f / s.fps);
        }
      }
      raf = requestAnimationFrame(tick);
    };

    return {
      init(el) {
        el.querySelectorAll<HTMLDivElement>('.dm-mcu-strip').forEach((stripEl, i) => {
          const tesla = createTesla();
          tesla.setFull(1);
          const desk = createDesktop({ wallpaper: ASSETS.wallpaper, clip: ASSETS.clip });
          desk.setMode('extend');
          desk.root.style.transform = `scale(${1920 / desk.layout.w}, ${1140 / desk.layout.h})`;
          desk.front(desk.player);
          desk.playerHud.style.display = 'none';
          desk.cursor.style.opacity = '1';
          tesla.viewport.appendChild(desk.root);
          const panel = stripEl.querySelector('.dm-mcu-panel') as HTMLDivElement;
          panel.appendChild(tesla.root);
          const s: Strip = { el: stripEl, panel, desk, fps: i === 0 ? 30 : 60, frame: -1 };
          pose(s, 0);
          strips.push(s);
        });
        const layout = () => {
          const W = el.clientWidth;
          const H = el.clientHeight;
          if (!W || !H) return;
          const small = W < 480 && H < 300;
          const pad = small ? 8 : Math.round(Math.min(W, H) * 0.05);
          const gap = small ? 6 : 12;
          const sh = (H - 2 * pad - gap) / 2;
          const k = sh / ROWS;
          el.classList.toggle('dm-mcu-small', 60 * k < 26 || W < 300);
          strips.forEach((s, i) => {
            Object.assign(s.el.style, { left: pad + 'px', top: pad + i * (sh + gap) + 'px', width: W - 2 * pad + 'px', height: sh + 'px' });
            s.panel.style.transform = `translate(${BEZEL * k}px, ${BEZEL * k}px) scale(${k})`;
            s.el.style.setProperty('--band', (BEZEL + 60) * k + 'px');
            s.el.style.setProperty('--bz', BEZEL * k + 'px');
          });
        };
        ro = new ResizeObserver(layout);
        ro.observe(el);
        layout();
      },
      play() {
        if (raf) return;
        t0 = performance.now() - held * 1000;
        raf = requestAnimationFrame(tick);
      },
      pause() {
        if (raf) held = (performance.now() - t0) / 1000;
        cancelAnimationFrame(raf);
        raf = 0;
      },
      still() {
        cancelAnimationFrame(raf);
        raf = 0;
        strips.forEach((s) => pose(s, PERIOD * 0.3));
      },
      destroy() {
        cancelAnimationFrame(raf);
        if (ro) ro.disconnect();
      },
    };
  });

  return (
    <div ref={ref} className="dm-vis dm-vis-mcu" aria-hidden="true">
      <div className="dm-mcu-strip dm-mcu-2">
        <div className="dm-mcu-panel" />
        <span className="dm-mcu-label">
          <b>MCU2</b> · Intel Atom · 720p30
        </span>
      </div>
      <div className="dm-mcu-strip dm-mcu-3">
        <div className="dm-mcu-panel" />
        <span className="dm-mcu-label">
          <b>MCU3</b> · AMD Ryzen · up to 60 fps
        </span>
      </div>
    </div>
  );
}
