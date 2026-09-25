import { useEffect, useRef, useState } from 'react';
import { GestureArt, type Gesture } from './Gestures';
import { revealWithin } from '../lib/motion';
import './Touch.css';

const GESTURES: { kind: Gesture; title: string; label: string }[] = [
  { kind: 'tap', title: 'Tap', label: 'Click' },
  { kind: 'drag', title: 'Drag', label: 'Click and drag' },
  { kind: 'scroll', title: 'Two fingers', label: 'Scroll, naturally' },
  { kind: 'hold', title: 'Hold', label: 'Right-click' },
  { kind: 'keys', title: 'Keyboard', label: 'Type into any app' },
];

/** tesla.com's small feature set ("Everything You Want" on /modely): the whole set at once, in an even grid. */
export function Touch() {
  const root = useRef<HTMLElement>(null);
  const [live, setLive] = useState(false);

  useEffect(() => {
    const el = root.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => setLive(e.isIntersecting), { rootMargin: '100px 0px' });
    io.observe(el);
    return () => io.disconnect();
  }, []);

  useEffect(() => (root.current ? revealWithin(root.current) : undefined), []);

  return (
    <section id="touch" className={`touch section${live ? ' is-live' : ''}`} ref={root} aria-labelledby="touch-title">
      <div className="wrap">
        <header className="section-head">
          <h2 id="touch-title" className="t-section" data-reveal="large">
            Touch is the mouse
          </h2>
          <p className="t-sub touch__sub" data-reveal="small" data-reveal-delay="0.1">
            The car&rsquo;s screen drives your Mac. Keyboard included.
          </p>
        </header>

        <ul className="touch__grid" aria-label="Gestures">
          {GESTURES.map((g, i) => (
            <li className={`tile tile--${g.kind}`} key={g.kind} data-reveal="small" data-reveal-delay={String(0.12 + 0.05 * i)}>
              <div className="tile__art">
                <GestureArt kind={g.kind} />
              </div>
              <div className="tile__text">
                <h3 className="tile__title">{g.title}</h3>
                <p className="tile__label">{g.label}</p>
              </div>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
