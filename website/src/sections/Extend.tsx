import { useEffect, useRef } from 'react';
import { Photo } from '../ui/Photo';
import { revealWithin } from '../lib/motion';
import './Extend.css';

const MODES = [
  { value: 'Extend', label: 'A HiDPI display sized to the car' },
  { value: 'Mirror', label: 'The screen you’re on' },
];

/** tesla.com home's split card (the FSD block): a grey card, copy and stats on the left, media on the right. */
export function Extend() {
  const root = useRef<HTMLElement>(null);
  useEffect(() => (root.current ? revealWithin(root.current) : undefined), []);

  return (
    <section id="extend" className="split-section section" ref={root} aria-labelledby="extend-title">
      <div className="split" data-reveal="small">
        <div className="split__copy">
          <h2 id="extend-title" className="split__title">
            Extend or mirror
          </h2>
          <p className="split__sub">A second display for your Mac, right on the dash.</p>
          <ul className="split__stats">
            {MODES.map((m) => (
              <li key={m.value}>
                <span className="split__value">{m.value}</span>
                <span className="split__label">{m.label}</span>
              </li>
            ))}
          </ul>
          <div className="split__ctas">
            <a className="btn btn--dark" href="#demo">
              Try it below
            </a>
          </div>
        </div>
        <div className="split__media">
          <Photo name="extend" alt="A Tesla Model 3 centre screen glowing in a dark cabin" tone="#292827" position="50% 55%" landscapeOnly />
        </div>
      </div>
    </section>
  );
}
