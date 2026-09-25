import type { ReactNode } from 'react';
import { Photo } from '../ui/Photo';
import { SoundVisual, McuVisual } from '../demo';
import { useCarousel } from '../hooks/useCarousel';
import './Features.css';

type Stat = { value: string; unit?: string; label: string };

type Feature = {
  id: string;
  title: string;
  sub: string;
  stats: Stat[];
  secondary: { label: string; href: string };
  media: ReactNode;
};

const FEATURES: Feature[] = [
  {
    id: 'extend',
    title: 'Extend or mirror',
    sub: 'A second display for your Mac, right on the dash.',
    stats: [
      { value: 'Extend', label: 'A HiDPI display sized to the car' },
      { value: 'Mirror', label: 'The screen you’re on' },
    ],
    secondary: { label: 'Learn more', href: '#app' },
    media: <Photo name="extend" alt="A Tesla Model 3 centre screen glowing in a dark cabin" tone="#171a20" position="50% 55%" landscapeOnly />,
  },
  {
    id: 'sound',
    title: 'Sound through the car',
    sub: 'Your Mac’s audio on the car’s speakers, in sync with the picture.',
    stats: [
      { value: '250', unit: 'ms', label: 'Cinema' },
      { value: '60', unit: 'ms', label: 'Interactive' },
      { value: 'Auto', label: 'Switches for you' },
    ],
    secondary: { label: 'Learn more', href: '#tech' },
    media: <SoundVisual />,
  },
  {
    id: 'mcu',
    title: 'Built for MCU2 and MCU3',
    sub: 'Quality is picked from how fast your car decodes, then tuned live.',
    stats: [
      { value: '720p30', label: 'MCU2 · Intel Atom' },
      { value: '60', unit: 'fps', label: 'MCU3 · AMD Ryzen' },
    ],
    secondary: { label: 'See every tier', href: '#tech' },
    media: <McuVisual />,
  },
];

/**
 * tesla.com home's FSD split card, as a row: a #f4f4f4 card across the content width (8px radius), copy on the left
 * (title, grey subtitle, a stat row, a dark + white button pair), media filling the right 60% at full height.
 * The next card peeks in; native scrolling (useCarousel) and Tesla's 12px dots underneath, no arrows.
 */
export function Features() {
  const { bind, index, goToIndex } = useCarousel('.split');

  return (
    <section id="features" className="split-section section" aria-labelledby="features-title">
      <h2 id="features-title" className="sr-only">
        Highlights
      </h2>
      <div className="srow" role="region" aria-roledescription="carousel" aria-label="Highlights">
        <ul className="srow__track snap-track" id="feature-cards" aria-label="Highlights, use the arrow keys to move" {...bind}>
          {FEATURES.map((f, i) => (
            <li className="split" key={f.id} id={`feature-${f.id}`} aria-roledescription="slide" aria-label={`${i + 1} of ${FEATURES.length}: ${f.title}`}>
              <div className="split__copy">
                <h3 className="split__title">{f.title}</h3>
                <p className="split__sub">{f.sub}</p>
                <ul className="split__stats">
                  {f.stats.map((s) => (
                    <li key={s.label}>
                      <span className="split__value">
                        {s.value}
                        {s.unit ? <span className="split__unit">{s.unit}</span> : null}
                      </span>
                      <span className="split__label">{s.label}</span>
                    </li>
                  ))}
                </ul>
                <div className="split__ctas">
                  <a className="btn btn--dark" href="#demo">
                    Try the demo
                  </a>
                  <a className="btn btn--light" href={f.secondary.href}>
                    {f.secondary.label}
                  </a>
                </div>
              </div>
              <div className="split__media">{f.media}</div>
            </li>
          ))}
        </ul>
      </div>
      <div className="srow__dots" role="group" aria-label="Choose a highlight">
        {FEATURES.map((f, i) => (
          <button
            key={f.id}
            type="button"
            className="srow__dot"
            aria-label={f.title}
            aria-controls={`feature-${f.id}`}
            aria-current={index === i ? 'true' : undefined}
            onClick={() => goToIndex(i)}
          />
        ))}
      </div>
    </section>
  );
}
