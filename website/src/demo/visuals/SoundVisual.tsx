import { DemoScreen } from '../screen';
import { useLive } from './useLive';
import { fitSlab } from './slab';
import './visuals.css';

const BARS = 9;

/**
 * "Sound through the car": the car's screen straight on, in Theater, streaming the Mac with the film
 * playing, and the client's playout readout (Cinema · 250 ms, A/V in sync) with a level meter for the
 * car speakers. Fills its positioned parent.
 */
export function SoundVisual() {
  const ref = useLive(() => {
    let screen: DemoScreen | null = null;
    let ro: ResizeObserver | null = null;
    let raf = 0;
    let bars: HTMLElement[] = [];
    const t0 = performance.now();

    const level = (i: number, t: number) => {
      // A soft, speech-and-music-like envelope per bar: a few incommensurate sines, never silent.
      const v = Math.sin(t * 5.1 + i * 1.7) * 0.5 + Math.sin(t * 8.3 + i * 0.9) * 0.3 + Math.sin(t * 2.3 + i * 2.9) * 0.2;
      const shape = 1 - Math.abs(i - (BARS - 1) / 2) / BARS;
      return Math.max(0.16, Math.min(1, (0.45 + 0.55 * v) * (0.55 + 0.45 * shape)));
    };
    const paint = (t: number) => bars.forEach((b, i) => (b.style.transform = `scaleY(${level(i, t).toFixed(3)})`));
    const tick = () => {
      paint((performance.now() - t0) / 1000);
      raf = requestAnimationFrame(tick);
    };

    return {
      init(el) {
        const slab = el.querySelector('.dm-slab') as HTMLDivElement;
        const hud = el.querySelector('.dm-sv-hud') as HTMLDivElement;
        bars = Array.from(el.querySelectorAll('.dm-sv-bars i')) as HTMLElement[];
        screen = new DemoScreen({ display: 'extend', tier: 'mcu3', stats: false, story: 'film' });
        slab.insertBefore(screen.el, slab.lastElementChild);
        const layout = () => {
          const W = el.clientWidth;
          const H = el.clientHeight;
          if (!W || !H) return;
          const f = fitSlab(W, H, Math.max(14, Math.min(W, H) * 0.08));
          slab.style.transform = `translate(${f.x}px, ${f.y}px) scale(${f.k})`;
          el.style.setProperty('--sx', f.x + 'px');
          el.style.setProperty('--sy', f.y + 'px');
          el.style.setProperty('--sw', f.w + 'px');
          el.style.setProperty('--sh', f.h + 'px');
          hud.classList.toggle('dm-sv-hud-small', W < 480);
        };
        ro = new ResizeObserver(layout);
        ro.observe(el);
        layout();
        paint(1.3);
      },
      play() {
        if (!screen) return;
        screen.play();
        if (!raf) raf = requestAnimationFrame(tick);
      },
      pause() {
        if (screen) screen.pause();
        cancelAnimationFrame(raf);
        raf = 0;
      },
      still() {
        cancelAnimationFrame(raf);
        raf = 0;
        if (screen) screen.still();
        paint(1.3);
      },
      destroy() {
        cancelAnimationFrame(raf);
        if (ro) ro.disconnect();
        if (screen) screen.destroy();
      },
    };
  });

  return (
    <div ref={ref} className="dm-vis dm-vis-sound" aria-hidden="true">
      <div className="dm-vis-glow" />
      <div className="dm-slab">
        <div className="dm-slab-frame" />
        <div className="dm-slab-sheen" />
      </div>
      <div className="dm-sv-hud">
        <div className="dm-sv-head">
          <span className="dm-sv-bars">
            {Array.from({ length: BARS }, (_, i) => (
              <i key={i} />
            ))}
          </span>
          Car speakers
        </div>
        <dl>
          <dt>Playout</dt>
          <dd>cinema · 250 ms</dd>
          <dt>A/V</dt>
          <dd className="dm-sv-good">in sync</dd>
        </dl>
        <div className="dm-sv-seg">
          <span>Interactive</span>
          <span className="dm-on">Cinema</span>
          <span>Auto</span>
        </div>
      </div>
    </div>
  );
}
