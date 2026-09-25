import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { gsap, ease, prefersReducedMotion } from '../lib/motion';
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
        {/* The brand wallpaper (public/shots/wallpaper.jpg): deep navy into its blue wave. */}
        <linearGradient id="office-screen" x1="0" y1="0" x2="0.35" y2="1">
          <stop offset="0" stopColor="#011138" />
          <stop offset="0.6" stopColor="#0a3f93" />
          <stop offset="1" stopColor="#0b52e0" />
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

/** How long each step stays up before the next, while nobody has picked one. */
const STEP_MS = 4800;

/**
 * "Your office, anywhere" on Powerwall's vertical carousel: the steps as a list on the left (the active one opens
 * its text), our line drawing on the right showing that step. The steps advance by themselves while the section
 * is on screen, until someone picks one; each change animates only the part of the scene that step adds.
 */
export function Office() {
  const root = useRef<HTMLElement>(null);
  const [active, setActive] = useState(0);
  const [inView, setInView] = useState(false);
  const [picked, setPicked] = useState(false);
  const [reduced] = useState(prefersReducedMotion);
  const shown = useRef(-1);

  /** Puts the scene in step `k`'s state: every earlier step already done, step k itself animated in. */
  const show = useCallback(
    (k: number, animate: boolean) => {
      const el = root.current;
      if (!el) return;
      const q = gsap.utils.selector(el);
      const parts = ['.o-bezel', '.o-glass, .o-ext', '.o-board', '.o-mac', '.o-ext-win'];
      parts.forEach((p) => gsap.killTweensOf(q(p)));
      const d = animate && !reduced ? 1 : 0;
      const screen = (turned: boolean) => {
        gsap.set(q('.o-bezel'), { attr: { d: turned ? SCREEN.turned : SCREEN.flat } });
        gsap.set(q('.o-glass, .o-ext'), { attr: { d: turned ? GLASS.turned : GLASS.flat } });
      };
      const board = (on: boolean) => gsap.set(q('.o-board'), { x: on ? 0 : 260, autoAlpha: on ? 1 : 0 });
      const desk = (on: boolean) => {
        gsap.set(q('.o-mac'), { y: on ? 0 : -40, autoAlpha: on ? 1 : 0 });
        gsap.set(q('.o-ext-win'), { x: on ? 0 : 276, y: on ? 0 : 64, scale: on ? 1 : 0.62, autoAlpha: on ? 1 : 0, transformOrigin: '0% 0%' });
      };

      screen(k > 0);
      board(k > 1);
      desk(false);
      if (k === 0) {
        screen(false);
        gsap.to(q('.o-bezel'), { attr: { d: SCREEN.turned }, duration: 0.9 * d, ease: ease.tds, delay: 0.3 * d });
        gsap.to(q('.o-glass, .o-ext'), { attr: { d: GLASS.turned }, duration: 0.9 * d, ease: ease.tds, delay: 0.3 * d });
      } else if (k === 1) {
        board(false);
        gsap.to(q('.o-board'), { x: 0, autoAlpha: 1, duration: 1 * d, ease: ease.mktg });
      } else {
        gsap.to(q('.o-mac'), { y: 0, autoAlpha: 1, duration: 0.7 * d, ease: ease.mktg });
        gsap.to(q('.o-ext-win'), { x: 0, y: 0, scale: 1, autoAlpha: 1, duration: 1 * d, ease: ease.slide, delay: 0.7 * d });
      }
      shown.current = k;
    },
    [reduced],
  );

  useEffect(() => {
    const el = root.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => setInView(e.isIntersecting), { threshold: 0.35 });
    io.observe(el);
    return () => io.disconnect();
  }, []);

  // Before it is first seen the scene waits on its opening frame: the screen flat, no board, no MacBook.
  useLayoutEffect(() => {
    const q = gsap.utils.selector(root.current);
    gsap.set(q('.o-bezel'), { attr: { d: SCREEN.flat } });
    gsap.set(q('.o-glass, .o-ext'), { attr: { d: GLASS.flat } });
    gsap.set(q('.o-board'), { x: 260, autoAlpha: 0 });
    gsap.set(q('.o-mac, .o-ext-win'), { autoAlpha: 0 });
  }, []);

  useEffect(() => {
    if (!inView && shown.current === -1) return;
    if (shown.current !== active) show(active, true);
  }, [active, inView, show]);

  useEffect(() => {
    if (reduced || !inView || picked) return;
    const t = window.setTimeout(() => setActive((a) => (a + 1) % STEPS.length), STEP_MS);
    return () => window.clearTimeout(t);
  }, [active, inView, picked, reduced]);

  useEffect(() => {
    const el = root.current;
    return () => {
      if (el) gsap.killTweensOf(gsap.utils.selector(el)('*'));
    };
  }, []);

  const choose = (i: number) => {
    setPicked(true);
    if (i === active && shown.current === i) show(i, true);
    setActive(i);
  };

  return (
    <section id="office" className="office section on-dark" ref={root} aria-labelledby="office-title">
      <div className="wrap">
        <header className="office__head">
          <h2 id="office-title" className="t-section">
            Your office, anywhere
          </h2>
          <p className="t-sub office__sub">Park, swivel, set up. A desk and a second screen, wherever you charge.</p>
        </header>

        <div className="office__row">
          <ol className="office__steps">
            {STEPS.map((s, i) => {
              const on = i === active;
              return (
                <li key={s.title} className={on ? 'is-on' : undefined}>
                  <button type="button" className="office__step" aria-expanded={on} aria-controls={`office-step-${i}`} onClick={() => choose(i)}>
                    <span className="office__title">{s.title}</span>
                  </button>
                  <p className="office__body" id={`office-step-${i}`} hidden={!on}>
                    {s.body}
                  </p>
                </li>
              );
            })}
          </ol>

          <div className="office__art">
            <Scene />
          </div>
        </div>

        <p className="office__note">Our setup, in a Model 3/Y. Parked only. Take the board out before you drive.</p>
      </div>
    </section>
  );
}
