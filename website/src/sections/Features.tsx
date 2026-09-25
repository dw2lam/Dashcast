import type { ReactNode } from 'react';
import { Photo } from '../ui/Photo';
import { SoundVisual, McuVisual } from '../demo';
import { ChevronIcon as Chevron } from '../ui/icons';
import { useCarousel } from '../hooks/useCarousel';
import './Features.css';

type Feature = {
  id: string;
  title: string;
  sub: string;
  primary: { label: string; href: string };
  secondary: { label: string; href: string };
  media: ReactNode;
};

const FEATURES: Feature[] = [
  {
    id: 'extend',
    title: 'Extend or mirror',
    sub: 'A second display for your Mac, right on the dash.',
    primary: { label: 'Try the demo', href: '#demo' },
    secondary: { label: 'Learn more', href: '#app' },
    media: <Photo name="extend" alt="A Tesla Model 3 centre screen glowing in a dark cabin" tone="#171a20" position="50% 55%" portraitPosition="62% 50%" />,
  },
  {
    id: 'sound',
    title: 'Sound through the car',
    sub: 'Your Mac’s audio on the car’s speakers, in sync with the picture.',
    primary: { label: 'Try the demo', href: '#demo' },
    secondary: { label: 'Learn more', href: '#tech' },
    media: <SoundVisual />,
  },
  {
    id: 'mcu',
    title: 'Built for MCU2 and MCU3',
    sub: 'Quality is picked from how fast your car decodes, then tuned live.',
    primary: { label: 'Try the demo', href: '#demo' },
    secondary: { label: 'See every tier', href: '#tech' },
    media: <McuVisual />,
  },
];

/**
 * tesla.com home's card carousel ("Solar Panels · Powerwall · Megapack"): big rounded media cards with the
 * title, subtitle and a blue + white button pair over the bottom-left of the media; the next card peeks in.
 * Native scrolling (useCarousel), a 40px arrow over the media on hover screens, and 12px dots underneath.
 */
export function Features() {
  const { bind, edge, index, step, goToIndex } = useCarousel('.fcard');

  return (
    <section id="features" className="fcards section" aria-labelledby="features-title">
      <h2 id="features-title" className="sr-only">
        Highlights
      </h2>
      <div className="fcards__wrap" role="region" aria-roledescription="carousel" aria-label="Highlights">
        <ul className="fcards__track snap-track" id="feature-cards" aria-label="Highlights, use the arrow keys to move" {...bind}>
          {FEATURES.map((f, i) => (
            <li className="fcard on-dark" key={f.id} id={`feature-${f.id}`} aria-roledescription="slide" aria-label={`${i + 1} of ${FEATURES.length}: ${f.title}`}>
              <div className="fcard__media">{f.media}</div>
              <div className="fcard__scrim" aria-hidden="true" />
              <div className="fcard__copy">
                <h3 className="fcard__title">{f.title}</h3>
                <p className="fcard__sub">{f.sub}</p>
                <div className="fcard__ctas">
                  <a className="btn btn--primary" href={f.primary.href}>
                    {f.primary.label}
                  </a>
                  <a className="btn btn--light" href={f.secondary.href}>
                    {f.secondary.label}
                  </a>
                </div>
              </div>
            </li>
          ))}
        </ul>
        <button className="fcards__arrow fcards__arrow--prev" type="button" aria-label="Previous highlight" aria-controls="feature-cards" onClick={() => step(-1)} disabled={edge.start}>
          <Chevron dir="left" />
        </button>
        <button className="fcards__arrow fcards__arrow--next" type="button" aria-label="Next highlight" aria-controls="feature-cards" onClick={() => step(1)} disabled={edge.end}>
          <Chevron dir="right" />
        </button>
      </div>
      <div className="fcards__dots" role="group" aria-label="Choose a highlight">
        {FEATURES.map((f, i) => (
          <button
            key={f.id}
            type="button"
            className="fcards__dot"
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
