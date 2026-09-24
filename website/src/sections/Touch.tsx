import { useCallback, useEffect, useRef, useState, type KeyboardEvent, type PointerEvent } from 'react';
import { GestureArt, type Gesture } from './Gestures';
import { ease, prefersReducedMotion, revealWithin } from '../lib/motion';
import './Touch.css';

const CARDS: { kind: Gesture; title: string; label: string; detail?: string }[] = [
  {
    kind: 'sound',
    title: 'Sound',
    label: 'Through the car speakers, in sync with the picture',
    detail: 'Cinema 250 ms · Interactive 60 ms · Auto',
  },
  {
    kind: 'mcu',
    title: 'MCU2 and MCU3',
    label: 'Quality picked from how fast your car decodes, tuned live',
    detail: '720p30 on Intel Atom · up to 60 fps on AMD Ryzen',
  },
  { kind: 'tap', title: 'Tap', label: 'Click' },
  { kind: 'drag', title: 'Drag', label: 'Click and drag' },
  { kind: 'scroll', title: 'Two fingers', label: 'Scroll, naturally' },
  { kind: 'hold', title: 'Hold', label: 'Right-click' },
  { kind: 'keys', title: 'Keyboard', label: 'Type into any app' },
];

function Chevron({ dir }: { dir: 'left' | 'right' }) {
  return (
    <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <path d={dir === 'left' ? 'M14.5 6l-6 6 6 6' : 'M9.5 6l6 6-6 6'} />
    </svg>
  );
}

type Drag = { id: number; x: number; left: number; lastX: number; lastT: number; v: number; moved: boolean };

/**
 * tesla.com's feature-card carousel ("Meet Model Y"): centred header, 8px-radius cards on a natively scrolling,
 * snapping track. Trackpad, shift+wheel and touch are the browser's own; a mouse can also grab and fling it,
 * with momentum and a snap to the nearest card. Arrow keys, Home and End step through it when focused.
 */
export function Touch() {
  const root = useRef<HTMLElement>(null);
  const track = useRef<HTMLUListElement>(null);
  const drag = useRef<Drag | null>(null);
  const raf = useRef(0);
  const gliding = useRef(false);
  const gesture = useRef<number | null>(null);
  const settleTimer = useRef(0);
  const suppressClick = useRef(false);
  const [edge, setEdge] = useState({ start: true, end: false });
  const [live, setLive] = useState(false);

  const measure = useCallback(() => {
    const t = track.current;
    if (!t) return;
    setEdge({ start: t.scrollLeft <= 2, end: t.scrollLeft + t.clientWidth >= t.scrollWidth - 2 });
  }, []);

  useEffect(() => {
    const t = track.current;
    if (!t) return;
    measure();
    t.addEventListener('scroll', measure, { passive: true });
    window.addEventListener('resize', measure);
    return () => {
      t.removeEventListener('scroll', measure);
      window.removeEventListener('resize', measure);
      cancelAnimationFrame(raf.current);
    };
  }, [measure]);

  useEffect(() => {
    const el = root.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => setLive(e.isIntersecting), { rootMargin: '100px 0px' });
    io.observe(el);
    return () => io.disconnect();
  }, []);

  useEffect(() => (root.current ? revealWithin(root.current) : undefined), []);

  /** Scroll positions that put each card at the start of the content column, clamped to the track. */
  const snaps = useCallback(() => {
    const t = track.current;
    if (!t) return [0];
    const cards = Array.from(t.querySelectorAll<HTMLElement>('.card'));
    const max = t.scrollWidth - t.clientWidth;
    const first = cards[0] ? cards[0].offsetLeft : 0;
    const pts = cards.map((c) => Math.min(max, Math.max(0, c.offsetLeft - first)));
    return pts.filter((p, i) => i === 0 || p !== pts[i - 1]);
  }, []);

  const nearest = useCallback(
    (x: number) => snaps().reduce((best, p) => (Math.abs(p - x) < Math.abs(best - x) ? p : best), 0),
    [snaps],
  );

  /** Tween scrollLeft (snap off meanwhile, so the browser's snapping doesn't fight the tween). */
  const glideTo = useCallback((target: number) => {
    const t = track.current;
    if (!t) return;
    cancelAnimationFrame(raf.current);
    gliding.current = false;
    const from = t.scrollLeft;
    const dist = target - from;
    if (Math.abs(dist) < 1 || prefersReducedMotion()) {
      t.scrollLeft = target;
      t.style.scrollSnapType = '';
      return;
    }
    gliding.current = true;
    t.style.scrollSnapType = 'none';
    const dur = Math.min(700, 360 + Math.abs(dist) * 0.35);
    const t0 = performance.now();
    const tick = (now: number) => {
      const k = Math.min(1, (now - t0) / dur);
      t.scrollLeft = from + dist * ease.mktg(k);
      if (k < 1) raf.current = requestAnimationFrame(tick);
      else {
        t.style.scrollSnapType = '';
        gliding.current = false;
      }
    };
    raf.current = requestAnimationFrame(tick);
  }, []);

  /**
   * Native scrolling (trackpad, touch) runs freely; once it stops, settle on a card in the direction of travel,
   * so even a short swipe pages to the next card. Shift + wheel scrolls sideways where the OS doesn't already.
   */
  useEffect(() => {
    const t = track.current;
    if (!t) return;
    const begin = () => {
      if (gesture.current === null) gesture.current = t.scrollLeft;
    };
    const settle = () => {
      const start = gesture.current;
      gesture.current = null;
      if (start === null || drag.current || gliding.current) return;
      const moved = t.scrollLeft - start;
      const pts = snaps();
      const pitch = pts.length > 1 ? pts[1] - pts[0] : t.clientWidth;
      glideTo(Math.abs(moved) < 24 ? nearest(start) : nearest(t.scrollLeft + Math.sign(moved) * pitch * 0.5));
    };
    const onWheel = (e: WheelEvent) => {
      if (e.shiftKey && Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
        const max = t.scrollWidth - t.clientWidth;
        const next = Math.max(0, Math.min(max, t.scrollLeft + e.deltaY));
        if (next !== t.scrollLeft) {
          e.preventDefault();
          begin();
          t.scrollLeft = next;
        }
        return;
      }
      if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) begin();
    };
    const onScroll = () => {
      if (gesture.current === null || drag.current || gliding.current) return;
      window.clearTimeout(settleTimer.current);
      settleTimer.current = window.setTimeout(settle, 160);
    };
    t.addEventListener('wheel', onWheel, { passive: false });
    t.addEventListener('touchstart', begin, { passive: true });
    t.addEventListener('scroll', onScroll, { passive: true });
    return () => {
      window.clearTimeout(settleTimer.current);
      t.removeEventListener('wheel', onWheel);
      t.removeEventListener('touchstart', begin);
      t.removeEventListener('scroll', onScroll);
    };
  }, [snaps, nearest, glideTo]);

  const step = (dir: 1 | -1) => {
    const t = track.current;
    if (!t) return;
    const pts = snaps();
    const here = nearest(t.scrollLeft);
    const i = pts.indexOf(here);
    glideTo(pts[Math.max(0, Math.min(pts.length - 1, i + dir))]);
  };

  const onPointerDown = (e: PointerEvent<HTMLUListElement>) => {
    if (e.pointerType !== 'mouse' || e.button !== 0) return;
    const t = track.current;
    if (!t) return;
    e.preventDefault();
    cancelAnimationFrame(raf.current);
    gliding.current = false;
    drag.current = { id: e.pointerId, x: e.clientX, left: t.scrollLeft, lastX: e.clientX, lastT: e.timeStamp, v: 0, moved: false };
  };

  const onPointerMove = (e: PointerEvent<HTMLUListElement>) => {
    const d = drag.current;
    const t = track.current;
    if (!d || !t || e.pointerId !== d.id) return;
    const dx = e.clientX - d.x;
    if (!d.moved) {
      if (Math.abs(dx) < 5) return;
      d.moved = true;
      t.setPointerCapture(e.pointerId);
      t.style.scrollSnapType = 'none';
      t.classList.add('is-dragging');
    }
    t.scrollLeft = d.left - dx;
    const dt = Math.max(1, e.timeStamp - d.lastT);
    d.v = 0.8 * ((e.clientX - d.lastX) / dt) + 0.2 * d.v;
    d.lastX = e.clientX;
    d.lastT = e.timeStamp;
  };

  const endDrag = (e: PointerEvent<HTMLUListElement>) => {
    const d = drag.current;
    const t = track.current;
    if (!d || !t || e.pointerId !== d.id) return;
    drag.current = null;
    if (!d.moved) return;
    if (t.hasPointerCapture(e.pointerId)) t.releasePointerCapture(e.pointerId);
    t.classList.remove('is-dragging');
    suppressClick.current = true;
    window.setTimeout(() => (suppressClick.current = false), 0);
    const idle = e.timeStamp - d.lastT > 80;
    const projected = t.scrollLeft - (idle ? 0 : d.v * 260);
    glideTo(nearest(projected));
  };

  const onKeyDown = (e: KeyboardEvent<HTMLUListElement>) => {
    const t = track.current;
    if (!t) return;
    const map: Record<string, () => void> = {
      ArrowRight: () => step(1),
      ArrowLeft: () => step(-1),
      Home: () => glideTo(0),
      End: () => glideTo(t.scrollWidth - t.clientWidth),
    };
    const fn = map[e.key];
    if (!fn) return;
    e.preventDefault();
    fn();
  };

  return (
    <section id="touch" className={`cards-section section${live ? ' is-live' : ''}`} ref={root} aria-labelledby="touch-title">
      <header className="section-head wrap">
        <h2 id="touch-title" className="t-section" data-reveal="large">
          Made for the car
        </h2>
        <p className="t-sub cards-section__sub" data-reveal="small" data-reveal-delay="0.1">
          Touch drives your Mac. Sound plays through the car.
        </p>
      </header>

      <div className="cards" role="region" aria-roledescription="carousel" aria-label="Made for the car" data-reveal="small" data-reveal-delay="0.15">
        <ul
          className="cards__track"
          id="touch-cards"
          ref={track}
          tabIndex={0}
          aria-label="Features, use the arrow keys to move"
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={endDrag}
          onPointerCancel={endDrag}
          onKeyDown={onKeyDown}
          onDragStart={(e) => e.preventDefault()}
          onClickCapture={(e) => {
            if (!suppressClick.current) return;
            suppressClick.current = false;
            e.preventDefault();
            e.stopPropagation();
          }}
        >
          {CARDS.map((c, i) => (
            <li className="card" key={c.kind} aria-roledescription="slide" aria-label={`${i + 1} of ${CARDS.length}: ${c.title}`}>
              <div className="card__art">
                <GestureArt kind={c.kind} />
              </div>
              <div className="card__text">
                <p className="card__title">{c.title}</p>
                <p className="card__label">{c.label}</p>
                {c.detail && <p className="card__detail">{c.detail}</p>}
              </div>
            </li>
          ))}
        </ul>
        <button className="cards__nav cards__nav--prev" type="button" aria-label="Previous card" aria-controls="touch-cards" onClick={() => step(-1)} disabled={edge.start}>
          <Chevron dir="left" />
        </button>
        <button className="cards__nav cards__nav--next" type="button" aria-label="Next card" aria-controls="touch-cards" onClick={() => step(1)} disabled={edge.end}>
          <Chevron dir="right" />
        </button>
      </div>
    </section>
  );
}
