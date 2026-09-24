import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';

gsap.registerPlugin(ScrollTrigger);

/** CSS cubic-bezier(x1, y1, x2, y2) as a GSAP ease (Newton–Raphson on x, then y). */
function bezier(x1: number, y1: number, x2: number, y2: number) {
  const cx = 3 * x1;
  const bx = 3 * (x2 - x1) - cx;
  const ax = 1 - cx - bx;
  const cy = 3 * y1;
  const by = 3 * (y2 - y1) - cy;
  const ay = 1 - cy - by;
  const sx = (t: number) => ((ax * t + bx) * t + cx) * t;
  const sy = (t: number) => ((ay * t + by) * t + cy) * t;
  const dx = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
  return (x: number) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const err = sx(t) - x;
      const d = dx(t);
      if (Math.abs(err) < 1e-5 || Math.abs(d) < 1e-6) break;
      t -= err / d;
    }
    return sy(Math.min(1, Math.max(0, t)));
  };
}

/** tesla.com's curves (tokens.css --ease, --ease-mktg, --ease-slide). */
export const ease = {
  tds: bezier(0.5, 0, 0, 0.75),
  mktg: bezier(0.165, 0.84, 0.44, 1),
  slide: bezier(0.75, 0, 0, 1),
};

export const prefersReducedMotion = () =>
  typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

type RevealKind = 'small' | 'large';

/**
 * Tesla's two reveal presets, driven by ScrollTrigger:
 *  small — 30px rise, 0.5s, marketing ease (.tds-animate_small--to_reveal)
 *  large — 100px rise, 1.5s, marketing ease (.tds-animate_large--to_reveal)
 * Elements opt in with data-reveal="small|large" and an optional data-reveal-delay (s).
 * Returns a cleanup function.
 */
export function revealWithin(root: HTMLElement): () => void {
  if (prefersReducedMotion()) return () => {};
  const ctx = gsap.context(() => {
    const els = gsap.utils.toArray<HTMLElement>('[data-reveal]', root);
    for (const el of els) {
      const kind = (el.dataset.reveal as RevealKind) || 'small';
      const delay = Number(el.dataset.revealDelay || 0);
      gsap.fromTo(
        el,
        { y: kind === 'large' ? 100 : 30, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: kind === 'large' ? 1.5 : 0.5,
          delay,
          ease: ease.mktg,
          scrollTrigger: { trigger: el, start: 'top 92%', once: true },
        },
      );
    }
  }, root);
  return () => ctx.revert();
}

/**
 * Sections owned by other agents (the demo, the showcase) settle their height after load; keep every
 * ScrollTrigger's start/end in step with the document instead of the first layout.
 */
export function refreshOnLayoutChange(el: HTMLElement): () => void {
  let t = 0;
  let last = el.offsetHeight;
  const ro = new ResizeObserver(() => {
    const h = el.offsetHeight;
    if (Math.abs(h - last) < 2) return;
    last = h;
    window.clearTimeout(t);
    t = window.setTimeout(() => ScrollTrigger.refresh(), 150);
  });
  ro.observe(el);
  return () => {
    window.clearTimeout(t);
    ro.disconnect();
  };
}

export { gsap, ScrollTrigger };
