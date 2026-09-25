import { useEffect, useRef, useState } from 'react';
import { GestureArt, type Gesture } from './Gestures';
import './Touch.css';

const GESTURES: { kind: Gesture; title: string; label: string }[] = [
  { kind: 'tap', title: 'Tap', label: 'Click' },
  { kind: 'drag', title: 'Drag', label: 'Click and drag' },
  { kind: 'scroll', title: 'Two fingers', label: 'Scroll, naturally' },
  { kind: 'hold', title: 'Hold', label: 'Right-click' },
  { kind: 'keys', title: 'Keyboard', label: 'Type into any app' },
];

/** /modely's "Everything You Want": a left-aligned heading over the whole set at once, as even grey tiles. */
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

  return (
    <section id="touch" className={`touch section${live ? ' is-live' : ''}`} ref={root} aria-labelledby="touch-title">
      <div className="wrap">
        <header className="touch__head">
          <h2 id="touch-title" className="t-section">
            Touch is the mouse
          </h2>
          <p className="t-sub touch__sub">
            The car&rsquo;s screen drives your Mac. Keyboard included.
          </p>
        </header>

        <ul className="touch__grid" aria-label="Gestures">
          {GESTURES.map((g) => (
            <li className={`tile tile--${g.kind}`} key={g.kind}>
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
