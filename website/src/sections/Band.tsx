import { useEffect, useRef } from 'react';
import { Photo } from '../ui/Photo';
import { gsap, ease, prefersReducedMotion } from '../lib/motion';
import './Band.css';

/** A quiet full-bleed photo break between white sections: one line, no chrome. */
export function Band() {
  const root = useRef<HTMLElement>(null);

  useEffect(() => {
    const el = root.current;
    if (!el || prefersReducedMotion()) return;
    const ctx = gsap.context(() => {
      gsap.fromTo('.photo img', { scale: 1.12 }, { scale: 1, ease: 'none', scrollTrigger: { trigger: el, start: 'top bottom', end: 'bottom top', scrub: true } });
      gsap.fromTo('.band__title', { y: 60, opacity: 0 }, { y: 0, opacity: 1, duration: 1.4, ease: ease.mktg, scrollTrigger: { trigger: el, start: 'top 70%', once: true } });
    }, el);
    return () => ctx.revert();
  }, []);

  return (
    <section className="band on-dark" ref={root} aria-labelledby="band-title">
      <Photo className="band__photo" name="mcu" alt="A Tesla Model 3 cabin and its centre screen" tone="#333a3b" position="50% 20%" portraitPosition="50% 20%" />
      <div className="band__scrim" aria-hidden="true" />
      <h2 id="band-title" className="t-section band__title">
        Nothing to install in the car.
      </h2>
    </section>
  );
}
