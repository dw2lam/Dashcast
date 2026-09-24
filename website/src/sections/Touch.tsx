import { useCallback, useEffect, useRef, useState } from 'react';
import { GestureArt, type Gesture } from './Gestures';
import { revealWithin } from '../lib/motion';
import './Touch.css';

const CARDS: { kind: Gesture; title: string; label: string }[] = [
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

/** tesla.com's feature-card carousel ("Meet Model Y"): centred header, 8px-radius cards, native snap scrolling. */
export function Touch() {
  const root = useRef<HTMLElement>(null);
  const track = useRef<HTMLUListElement>(null);
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

  const step = (dir: 1 | -1) => {
    const t = track.current;
    const card = t?.querySelector<HTMLElement>('.card');
    if (!t || !card) return;
    const gap = parseFloat(getComputedStyle(t).columnGap || '16') || 16;
    t.scrollBy({ left: dir * (card.offsetWidth + gap), behavior: 'smooth' });
  };

  return (
    <section id="touch" className={`cards-section section${live ? ' is-live' : ''}`} ref={root} aria-labelledby="touch-title">
      <header className="section-head wrap">
        <h2 id="touch-title" className="t-section" data-reveal="large">
          Touch is the mouse
        </h2>
        <p className="t-sub cards-section__sub" data-reveal="small" data-reveal-delay="0.1">
          The car&rsquo;s screen drives your Mac. Keyboard included.
        </p>
      </header>

      <div className="cards" data-reveal="small" data-reveal-delay="0.15">
        <ul className="cards__track" ref={track} aria-label="Gestures">
          {CARDS.map((c) => (
            <li className="card" key={c.kind}>
              <div className="card__art">
                <GestureArt kind={c.kind} />
              </div>
              <div className="card__text">
                <p className="card__title">{c.title}</p>
                <p className="card__label">{c.label}</p>
              </div>
            </li>
          ))}
        </ul>
        <button className="cards__nav cards__nav--prev" type="button" aria-label="Previous gesture" onClick={() => step(-1)} disabled={edge.start}>
          <Chevron dir="left" />
        </button>
        <button className="cards__nav cards__nav--next" type="button" aria-label="Next gesture" onClick={() => step(1)} disabled={edge.end}>
          <Chevron dir="right" />
        </button>
      </div>
    </section>
  );
}
