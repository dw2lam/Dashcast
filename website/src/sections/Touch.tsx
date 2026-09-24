import { useEffect, useRef, useState } from 'react';
import { GestureArt, type Gesture } from './Gestures';
import { useCarousel } from '../hooks/useCarousel';
import { ChevronIcon as Chevron } from '../ui/icons';
import { revealWithin } from '../lib/motion';
import './Touch.css';

const CARDS: { kind: Gesture; title: string; label: string }[] = [
  { kind: 'tap', title: 'Tap', label: 'Click' },
  { kind: 'drag', title: 'Drag', label: 'Click and drag' },
  { kind: 'scroll', title: 'Two fingers', label: 'Scroll, naturally' },
  { kind: 'hold', title: 'Hold', label: 'Right-click' },
  { kind: 'keys', title: 'Keyboard', label: 'Type into any app' },
];

/** tesla.com's feature-card carousel ("Meet Model Y"): the touch gestures, on the shared useCarousel track. */
export function Touch() {
  const root = useRef<HTMLElement>(null);
  const [live, setLive] = useState(false);
  const { bind, edge, step } = useCarousel('.card');

  useEffect(() => {
    const el = root.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => setLive(e.isIntersecting), { rootMargin: '100px 0px' });
    io.observe(el);
    return () => io.disconnect();
  }, []);

  useEffect(() => (root.current ? revealWithin(root.current) : undefined), []);

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

      <div className="cards" role="region" aria-roledescription="carousel" aria-label="Touch gestures" data-reveal="small" data-reveal-delay="0.15">
        <ul className="cards__track snap-track" id="touch-cards" aria-label="Gestures, use the arrow keys to move" {...bind}>
          {CARDS.map((c, i) => (
            <li className="card" key={c.kind} aria-roledescription="slide" aria-label={`${i + 1} of ${CARDS.length}: ${c.title}`}>
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
        <button className="cards__nav cards__nav--prev" type="button" aria-label="Previous gesture" aria-controls="touch-cards" onClick={() => step(-1)} disabled={edge.start}>
          <Chevron dir="left" />
        </button>
        <button className="cards__nav cards__nav--next" type="button" aria-label="Next gesture" aria-controls="touch-cards" onClick={() => step(1)} disabled={edge.end}>
          <Chevron dir="right" />
        </button>
      </div>
    </section>
  );
}
