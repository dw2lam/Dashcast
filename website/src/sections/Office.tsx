import { useEffect, useRef } from 'react';
import { gsap, ease, prefersReducedMotion, revealWithin } from '../lib/motion';
import './Office.css';

const STEPS = [
  { title: 'Swivel the screen', body: 'Optional: a third-party swivel mount turns the display toward you.' },
  { title: 'Lift out the trunk floor', body: 'The rear trunk’s subfloor cover comes right out.' },
  { title: 'Make a desk', body: 'Rest it below the screen, over the wheel. Your MacBook sits on it; the car screen is its second display.' },
];

/** Screen outline before (flat, facing the cabin) and after the swivel (turned toward the driver). */
const BEZEL = { flat: '470,100 770,100 770,288 470,288', turned: '484,114 772,96 772,292 484,276' };
const GLASS = { flat: '480,110 760,110 760,278 480,278', turned: '494,124 762,108 762,282 494,266' };

/** Our own line drawing of the setup, seen from the driver's seat. Every part is a hairline; one accent. */
function Scene() {
  return (
    <svg className="office__scene" viewBox="0 0 960 520" aria-hidden="true">
      <defs>
        <linearGradient id="office-screen" x1="0" y1="1" x2="1" y2="0">
          <stop offset="0" stopColor="#0872FE" />
          <stop offset="0.55" stopColor="#15ABFE" />
          <stop offset="1" stopColor="#18D3FD" />
        </linearGradient>
      </defs>
      <g className="o-cabin">
        <path className="o-line o-draw o-faint" d="M150 58 C 380 30, 580 30, 810 58" />
        <path className="o-line o-draw o-faint" d="M150 58 L 40 250 M810 58 L 920 250" />
        <path className="o-line o-draw" d="M40 250 C 260 226, 700 226, 920 250" />
        <path className="o-line o-draw o-faint" d="M60 300 C 280 282, 680 282, 900 300" />
      </g>
      <g className="o-wheel">
        <circle className="o-line o-draw" cx="300" cy="424" r="96" />
        <circle className="o-line o-draw o-faint" cx="300" cy="424" r="78" />
        <path className="o-line o-draw" d="M222 440 C 250 424, 350 424, 378 440 M300 440 L 300 520" />
      </g>
      <g className="o-screen">
        <path className="o-line o-draw" d="M628 290 L 628 316 M596 316 L 660 316" />
        <polygon className="o-bezel o-line o-draw" points={BEZEL.turned} />
        <polygon className="o-glass" points={GLASS.turned} />
        <polygon className="o-ext" points={GLASS.turned} fill="url(#office-screen)" />
        <polygon className="o-ext-win" points="548,150 700,142 700,228 548,234" />
      </g>
      <g className="o-board">
        <polygon className="o-board-top" points="196,322 728,322 770,356 152,356" />
        <polygon className="o-board-edge" points="152,356 770,356 770,368 152,368" />
      </g>
      <g className="o-mac">
        <polygon className="o-mac-base" points="228,318 420,318 442,330 206,330" />
        <rect className="o-mac-lid" x="244" y="220" width="160" height="98" rx="6" />
        <rect className="o-mac-glass" x="252" y="228" width="144" height="82" rx="3" fill="url(#office-screen)" />
        <rect className="o-mac-win" x="268" y="244" width="72" height="46" rx="3" />
      </g>
    </svg>
  );
}

/** "Your office, anywhere": the car-office setup as a dark, illustrated break between white sections. */
export function Office() {
  const root = useRef<HTMLElement>(null);

  useEffect(() => (root.current ? revealWithin(root.current) : undefined), []);

  useEffect(() => {
    const el = root.current;
    if (!el || prefersReducedMotion()) return;
    const ctx = gsap.context(() => {
      const draws = gsap.utils.toArray<SVGGeometryElement>('.o-draw');
      draws.forEach((p) => {
        const len = p.getTotalLength ? p.getTotalLength() : 1000;
        gsap.set(p, { strokeDasharray: len, strokeDashoffset: len });
      });
      const tl = gsap.timeline({ scrollTrigger: { trigger: '.office__scene', start: 'top 72%', once: true } });
      tl.to(draws, { strokeDashoffset: 0, duration: 1.1, stagger: 0.04, ease: ease.mktg }, 0)
        .fromTo('.o-bezel', { attr: { points: BEZEL.flat } }, { attr: { points: BEZEL.turned }, duration: 0.9, ease: ease.tds }, 0.9)
        .fromTo('.o-glass, .o-ext', { attr: { points: GLASS.flat } }, { attr: { points: GLASS.turned }, duration: 0.9, ease: ease.tds }, 0.9)
        .fromTo('.o-board', { y: 150, opacity: 0 }, { y: 0, opacity: 1, duration: 0.9, ease: ease.mktg }, 1.6)
        .fromTo('.o-mac', { y: -40, opacity: 0 }, { y: 0, opacity: 1, duration: 0.7, ease: ease.mktg }, 2.3)
        .fromTo('.o-ext', { opacity: 0 }, { opacity: 1, duration: 0.6, ease: 'none' }, 2.9)
        .fromTo('.o-ext-win', { x: -280, y: 102, scale: 0.48, opacity: 0, transformOrigin: '0% 0%' }, { x: 0, y: 0, scale: 1, opacity: 1, duration: 1, ease: ease.slide }, 3.0);
    }, el);
    return () => ctx.revert();
  }, []);

  return (
    <section id="office" className="office section on-dark" ref={root} aria-labelledby="office-title">
      <div className="wrap">
        <header className="section-head">
          <h2 id="office-title" className="t-section" data-reveal="large">
            Your office, anywhere
          </h2>
          <p className="t-sub office__sub" data-reveal="small" data-reveal-delay="0.1">
            Park, swivel, set up. A desk and a second screen, wherever you charge.
          </p>
        </header>

        <div className="office__art">
          <Scene />
        </div>

        <ol className="office__steps">
          {STEPS.map((s, i) => (
            <li key={s.title} data-reveal="small" data-reveal-delay={String(0.08 * i)}>
              <span className="office__n">{i + 1}</span>
              <p className="office__title">{s.title}</p>
              <p className="office__body">{s.body}</p>
            </li>
          ))}
        </ol>

        <p className="office__note" data-reveal="small">
          Our setup, in a Model 3/Y. Parked only. Take the board out before you drive.
        </p>
      </div>
    </section>
  );
}
