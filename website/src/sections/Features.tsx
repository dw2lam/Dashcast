import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Photo } from '../ui/Photo';
import { SoundVisual, McuVisual } from '../demo';
import { ChevronIcon as Chevron } from '../ui/icons';
import { useCarousel } from '../hooks/useCarousel';
import { revealWithin } from '../lib/motion';
import './Features.css';

type Feature = {
  id: string;
  title: string;
  sub: string;
  stats: { value: string; label: string }[];
  cta?: { label: string; href: string };
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
    cta: { label: 'Try it below', href: '#demo' },
    media: <Photo name="extend" alt="A Tesla Model 3 centre screen glowing in a dark cabin" tone="#292827" position="50% 55%" landscapeOnly />,
  },
  {
    id: 'sound',
    title: 'Sound through the car',
    sub: 'Your Mac’s audio on the car’s speakers, in sync with the picture.',
    stats: [
      { value: '250 ms', label: 'Cinema' },
      { value: '60 ms', label: 'Interactive' },
      { value: 'Auto', label: 'Switches for you' },
    ],
    media: <SoundVisual />,
  },
  {
    id: 'mcu',
    title: 'Built for MCU2 and MCU3',
    sub: 'Quality is picked from how fast your car decodes, then tuned live.',
    stats: [
      { value: '720p30', label: 'MCU2 · Intel Atom' },
      { value: '60 fps', label: 'MCU3 · AMD Ryzen' },
    ],
    cta: { label: 'See every tier', href: '#tech' },
    media: <McuVisual />,
  },
];

/**
 * tesla.com home's big split cards (#f4f4f4, 8px radius, copy left, media right) as a row: each card about
 * 88% of the content width with the next one peeking, arrows and dots, on the shared useCarousel track.
 */
export function Features() {
  const root = useRef<HTMLElement>(null);
  const [live, setLive] = useState(false);
  const { bind, edge, index, step, goToIndex } = useCarousel('.split');

  useEffect(() => {
    const el = root.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => setLive(e.isIntersecting), { rootMargin: '100px 0px' });
    io.observe(el);
    return () => io.disconnect();
  }, []);

  useEffect(() => (root.current ? revealWithin(root.current) : undefined), []);

  return (
    <section id="features" className={`split-section section${live ? ' is-live' : ''}`} ref={root} aria-labelledby="features-title">
      <h2 id="features-title" className="sr-only">
        Highlights
      </h2>
      <div className="srow" role="region" aria-roledescription="carousel" aria-label="Highlights" data-reveal="small">
        <ul className="srow__track snap-track" id="feature-cards" aria-label="Highlights, use the arrow keys to move" {...bind}>
          {FEATURES.map((f, i) => (
            <li className="split" key={f.id} id={`feature-${f.id}`} aria-roledescription="slide" aria-label={`${i + 1} of ${FEATURES.length}: ${f.title}`}>
              <div className="split__copy">
                <h3 className="split__title">{f.title}</h3>
                <p className="split__sub">{f.sub}</p>
                <ul className={`split__stats split__stats--${f.stats.length}`}>
                  {f.stats.map((s) => (
                    <li key={s.value}>
                      <span className="split__value">{s.value}</span>
                      <span className="split__label">{s.label}</span>
                    </li>
                  ))}
                </ul>
                {f.cta && (
                  <div className="split__ctas">
                    <a className="btn btn--dark" href={f.cta.href}>
                      {f.cta.label}
                    </a>
                  </div>
                )}
              </div>
              <div className="split__media">{f.media}</div>
            </li>
          ))}
        </ul>
        <div className="srow__controls">
          <button className="srow__nav" type="button" aria-label="Previous highlight" aria-controls="feature-cards" onClick={() => step(-1)} disabled={edge.start}>
            <Chevron dir="left" />
          </button>
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
          <button className="srow__nav" type="button" aria-label="Next highlight" aria-controls="feature-cards" onClick={() => step(1)} disabled={edge.end}>
            <Chevron dir="right" />
          </button>
        </div>
      </div>
    </section>
  );
}
