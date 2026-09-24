import { useEffect, useRef } from 'react';
import { gsap, ease, prefersReducedMotion, revealWithin } from '../lib/motion';
import './Office.css';

const STEPS = [
  { title: 'Swivel the screen', body: 'Optional: a third-party swivel mount turns the display toward you.' },
  { title: 'Lift out the trunk floor', body: 'The rear trunk’s subfloor cover comes right out.' },
  {
    title: 'Make a desk',
    body: 'Slide it under the wheel, below the screen; the wheel holds it in place. Your MacBook sits on the passenger side.',
  },
];

type Quad = [number, number][];

/** A quad with rounded corners as one path; the same command structure for every shape, so GSAP can morph it. */
function rounded(q: Quad, r: number) {
  const f = (n: number) => Math.round(n * 10) / 10;
  const at = (from: [number, number], to: [number, number], d: number): [number, number] => {
    const len = Math.hypot(to[0] - from[0], to[1] - from[1]) || 1;
    return [from[0] + ((to[0] - from[0]) * d) / len, from[1] + ((to[1] - from[1]) * d) / len];
  };
  let d = '';
  for (let i = 0; i < 4; i++) {
    const prev = q[(i + 3) % 4];
    const cur = q[i];
    const next = q[(i + 1) % 4];
    const a = at(cur, prev, r);
    const b = at(cur, next, r);
    d += `${i === 0 ? 'M' : 'L'}${f(a[0])} ${f(a[1])} Q${f(cur[0])} ${f(cur[1])} ${f(b[0])} ${f(b[1])} `;
  }
  return `${d}Z`;
}

/**
 * The centre screen before and after the optional swivel. Turning it toward the right (passenger) seat brings
 * its left edge toward us and sends the right edge away, so the right edge gets shorter.
 */
const SCREEN = {
  flat: rounded([[373, 112], [587, 112], [587, 246], [373, 246]], 13),
  turned: rounded([[376, 106], [582, 117], [582, 240], [376, 252]], 13),
};
const GLASS = {
  flat: rounded([[381, 120], [579, 120], [579, 238], [381, 238]], 6),
  turned: rounded([[384, 114], [574, 124], [574, 233], [384, 244]], 6),
};

/**
 * Our own line drawing of the setup in a left-hand-drive car, seen from the back seat: the centre screen floating
 * on the dash, the wheel on the left holding the trunk's subfloor cover down, the MacBook on the passenger side.
 */
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
        <path className="o-line o-draw o-faint" d="M150 50 C 380 22, 580 22, 810 50" />
        <path className="o-line o-draw o-faint" d="M150 50 L 40 244 M810 50 L 920 244" />
        <path className="o-line o-draw" d="M40 244 C 260 222, 700 222, 920 244" />
        <path className="o-line o-draw o-faint" d="M52 300 C 280 282, 680 282, 908 300" />
        <path className="o-line o-draw o-faint" d="M480 252 L 480 262" />
      </g>
      <g className="o-screen">
        <path className="o-bezel o-line o-draw" d={SCREEN.turned} />
        <path className="o-glass" d={GLASS.turned} />
        <path className="o-ext" d={GLASS.turned} fill="url(#office-screen)" />
        <polygon className="o-ext-win" points="414,146 520,142 520,204 414,209" />
      </g>
      <g className="o-wheel-back">
        <path className="o-line o-draw" d="M148 352 C 182 336, 278 336, 312 352 M230 348 L 230 432" />
        <circle className="o-line o-draw o-faint" cx="230" cy="350" r="16" />
        <path className="o-line o-draw o-faint" d="M230 450 L 230 520" />
      </g>
      <g className="o-board">
        <polygon className="o-board-top" points="118,286 830,286 862,316 92,316" />
        <polygon className="o-board-edge" points="92,316 862,316 862,328 92,328" />
      </g>
      <g className="o-wheel">
        <circle className="o-rim o-line o-draw" cx="230" cy="350" r="100" />
        <circle className="o-line o-draw o-faint" cx="230" cy="350" r="82" />
      </g>
      <g className="o-mac">
        <polygon className="o-mac-base" points="650,280 816,280 834,292 632,292" />
        <rect className="o-mac-lid" x="664" y="186" width="138" height="94" rx="6" />
        <rect className="o-mac-glass" x="671" y="193" width="124" height="80" rx="3" fill="url(#office-screen)" />
        <rect className="o-mac-win" x="690" y="210" width="66" height="44" rx="3" />
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
      tl.to(draws, { strokeDashoffset: 0, duration: 1, stagger: 0.04, ease: ease.mktg }, 0)
        .set(draws, { clearProps: 'strokeDasharray,strokeDashoffset' }, 1.5)
        .fromTo('.o-bezel', { attr: { d: SCREEN.flat } }, { attr: { d: SCREEN.turned }, duration: 0.9, ease: ease.tds }, 1.5)
        .fromTo('.o-glass, .o-ext', { attr: { d: GLASS.flat } }, { attr: { d: GLASS.turned }, duration: 0.9, ease: ease.tds }, 1.5)
        .fromTo('.o-board', { x: 260, opacity: 0 }, { x: 0, opacity: 1, duration: 1, ease: ease.mktg }, 2.3)
        .fromTo('.o-mac', { y: -40, opacity: 0 }, { y: 0, opacity: 1, duration: 0.7, ease: ease.mktg }, 3.1)
        .fromTo('.o-ext', { opacity: 0 }, { opacity: 1, duration: 0.6, ease: 'none' }, 3.7)
        .fromTo('.o-ext-win', { x: 276, y: 64, scale: 0.62, opacity: 0, transformOrigin: '0% 0%' }, { x: 0, y: 0, scale: 1, opacity: 1, duration: 1, ease: ease.slide }, 3.8);
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
