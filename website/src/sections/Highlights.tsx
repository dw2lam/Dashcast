import { useEffect, useRef } from 'react';
import { Photo } from '../ui/Photo';
import { gsap, ease, prefersReducedMotion } from '../lib/motion';
import { HIGHLIGHTS, type Highlight } from './highlight-data';
import './Highlights.css';

function HighlightSection({ h }: { h: Highlight }) {
  const root = useRef<HTMLElement>(null);

  useEffect(() => {
    const el = root.current;
    if (!el || prefersReducedMotion()) return;
    const ctx = gsap.context(() => {
      gsap.fromTo(
        '.photo img',
        { scale: 1.14 },
        { scale: 1, ease: 'none', scrollTrigger: { trigger: el, start: 'top bottom', end: 'top top', scrub: true } },
      );
      gsap.to('.photo img', {
        yPercent: 6,
        ease: 'none',
        scrollTrigger: { trigger: el, start: 'top top', end: 'bottom top', scrub: true },
      });
      const tl = gsap.timeline({ scrollTrigger: { trigger: el, start: 'top 62%', once: true } });
      tl.fromTo('.feature__title', { y: 100, opacity: 0 }, { y: 0, opacity: 1, duration: 1.5, ease: ease.mktg }, 0)
        .fromTo('.feature__sub', { y: 60, opacity: 0 }, { y: 0, opacity: 1, duration: 1.5, ease: ease.mktg }, 0.12);
      if (el.querySelector('.feature__stats')) {
        gsap.fromTo(
          '.feature__stats .stat',
          { y: 30, opacity: 0 },
          {
            y: 0,
            opacity: 1,
            duration: 0.9,
            stagger: 0.1,
            ease: ease.mktg,
            scrollTrigger: { trigger: '.feature__stats', start: 'top 95%', once: true },
          },
        );
      }
    }, el);
    return () => ctx.revert();
  }, []);

  return (
    <section id={h.id} ref={root} className={`feature section${h.theme === 'dark' ? ' on-dark' : ''}`}
      data-theme={h.theme}
      data-scrim={h.scrim} aria-labelledby={`${h.id}-title`}>
      <Photo className="feature__photo" name={h.media} alt={h.alt} tone={h.tone} position={h.position} portraitPosition={h.portraitPosition} />
      <div className="feature__scrim" aria-hidden="true" />
      <div className="feature__head">
        <h2 id={`${h.id}-title`} className="t-section feature__title">
          {h.title}
        </h2>
        <p className="t-sub feature__sub">{h.sub}</p>
      </div>
      {h.stats && (
        <ul className="stats feature__stats">
          {h.stats.map((s) => (
            <li className="stat" key={s.label}>
              <span className="stat__value">
                {s.value}
                {s.unit && <span className="stat__unit">{s.unit}</span>}
              </span>
              <span className="stat__label">{s.label}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

export function Highlights() {
  return (
    <div className="highlights">
      {HIGHLIGHTS.map((h) => (
        <HighlightSection key={h.id} h={h} />
      ))}
    </div>
  );
}
