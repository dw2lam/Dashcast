import { useEffect, useRef } from 'react';
import { CabinScreen } from '../demo';
import { gsap, ease, prefersReducedMotion } from '../lib/motion';
import { CAR_ADDRESS } from '../lib/links';
import { useInTesla } from '../hooks/useInTesla';
import './Hero.css';

const STATS = [
  { value: '60', unit: 'fps', label: 'on MCU3' },
  { value: 'HEVC', unit: '', label: 'or H.264' },
  { value: '48', unit: 'kHz', label: 'stereo, in sync' },
  { value: '0', unit: '', label: 'cloud servers' },
];

export function Hero() {
  const root = useRef<HTMLElement>(null);
  const inTesla = useInTesla();

  useEffect(() => {
    const el = root.current;
    if (!el || prefersReducedMotion()) return;
    const ctx = gsap.context(() => {
      const tl = gsap.timeline({ defaults: { ease: ease.mktg } });
      tl.fromTo('.hero__media', { scale: 1.08 }, { scale: 1, duration: 2.2 }, 0)
        .fromTo('.hero__title', { y: 30, opacity: 0 }, { y: 0, opacity: 1, duration: 1 }, 0.15)
        .fromTo('.hero__sub', { y: 30, opacity: 0 }, { y: 0, opacity: 1, duration: 1 }, 0.25)
        .fromTo('.hero__ctas', { y: 30, opacity: 0 }, { y: 0, opacity: 1, duration: 1 }, 0.35)
        .fromTo('.hero__stats .stat', { y: 40, opacity: 0 }, { y: 0, opacity: 1, duration: 1.2, stagger: 0.08 }, 0.45);

      gsap.to('.hero__content', {
        yPercent: -18,
        opacity: 0,
        ease: 'none',
        scrollTrigger: { trigger: el, start: 'top top', end: '60% top', scrub: true },
      });
      gsap.to('.hero__stats', {
        opacity: 0,
        y: -24,
        ease: 'none',
        scrollTrigger: { trigger: el, start: '20% top', end: '70% top', scrub: true },
      });
    }, el);
    return () => ctx.revert();
  }, []);

  return (
    <section id="top" className="hero on-dark" ref={root} aria-label="Dashcast">
      <div className="hero__media">
        <CabinScreen autoplay />
      </div>
      <div className="hero__scrim hero__scrim--top" aria-hidden="true" />
      <div className="hero__scrim hero__scrim--bottom" aria-hidden="true" />

      <div className="hero__content">
        <h1 className="t-hero hero__title">Dashcast</h1>
        <p className="t-sub hero__sub">
          {inTesla ? <>You&rsquo;re in your Tesla. Start casting on your Mac, then open it here.</> : <>Your Mac, on your Tesla&rsquo;s screen.</>}
        </p>
        <div className="btn-row hero__ctas">
          {inTesla ? (
            <>
              <a className="btn btn--primary" href={`http://${CAR_ADDRESS}`}>
                Open {CAR_ADDRESS}
              </a>
              <a className="btn btn--light" href="#connect">
                How to connect
              </a>
            </>
          ) : (
            <>
              <a className="btn btn--primary" href="#download">
                Download for Mac
              </a>
              <a className="btn btn--light" href="#demo">
                See it in the car
              </a>
            </>
          )}
        </div>
      </div>

      <ul className="stats hero__stats" aria-label="At a glance">
        {STATS.map((s) => (
          <li className="stat" key={s.label}>
            <span className="stat__value">
              {s.value}
              {s.unit && <span className="stat__unit">{s.unit}</span>}
            </span>
            <span className="stat__label">{s.label}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
