import { ScrollToPlugin } from 'gsap/ScrollToPlugin';
import { gsap, ScrollTrigger, ease, prefersReducedMotion } from './motion';

gsap.registerPlugin(ScrollToPlugin);

export type NavPhase = 'start' | 'end';
export const NAV_EVENT = 'dashcast:navigate';

const navH = () => parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--nav-h')) || 56;

/**
 * Document y where `el` sits in normal flow. A ScrollTrigger pin lifts its element out of flow into a
 * `.pin-spacer`; the spacer keeps the real position, so measure that instead.
 */
function flowTop(el: HTMLElement) {
  const spacer = el.parentElement && el.parentElement.classList.contains('pin-spacer') ? el.parentElement : el;
  return spacer.getBoundingClientRect().top + window.scrollY;
}

function targetY(el: HTMLElement) {
  const max = document.documentElement.scrollHeight - window.innerHeight;
  // The closing section hides the nav, so it lands flush with the top of the viewport.
  const offset = el.id === 'download' ? 0 : navH();
  return Math.max(0, Math.min(max, Math.round(flowTop(el) - offset)));
}

function emit(phase: NavPhase, id: string) {
  window.dispatchEvent(new CustomEvent(NAV_EVENT, { detail: { phase, id } }));
}

function focusHeading(el: HTMLElement) {
  const h = el.querySelector<HTMLElement>('h1, h2');
  if (!h) return;
  if (!h.hasAttribute('tabindex')) h.setAttribute('tabindex', '-1');
  h.focus({ preventScroll: true });
}

let tween: gsap.core.Tween | null = null;

/**
 * Scroll so section `id` starts right under the sticky nav: one eased tween (GSAP ScrollTo, which works on
 * Chromium 79 too), a final correction against the live layout, then the hash and focus. Instant under
 * reduced motion.
 */
export function goTo(id: string, opts: { instant?: boolean; focus?: boolean } = {}) {
  const el = document.getElementById(id);
  if (!el) return;
  const { instant = false, focus = true } = opts;
  tween?.kill();
  emit('start', id);

  const finish = () => {
    const y = targetY(el);
    if (Math.abs(window.scrollY - y) > 1) window.scrollTo(0, y);
    history.replaceState(null, '', id === 'top' ? location.pathname + location.search : `#${id}`);
    if (focus) focusHeading(el);
    emit('end', id);
  };

  const y = targetY(el);
  if (instant || prefersReducedMotion()) {
    window.scrollTo(0, y);
    finish();
    return;
  }
  const dist = Math.abs(window.scrollY - y);
  tween = gsap.to(window, {
    scrollTo: { y, autoKill: true, onAutoKill: () => emit('end', id) },
    duration: Math.min(1.2, 0.45 + dist / 6000),
    ease: ease.slide,
    onComplete: finish,
  });
}

/**
 * Every same-page anchor (nav, menu sheet, CTAs, in-copy links) goes through goTo. Deep links such as
 * /#faq land after fonts, images and ScrollTrigger pins have settled, and are re-checked while late
 * layout (the demo, the showcase) finishes, unless the visitor has started scrolling.
 */
export function installNavigation() {
  const onClick = (e: MouseEvent) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = (e.target as Element | null)?.closest?.('a[href^="#"]') as HTMLAnchorElement | null;
    if (!a) return;
    const id = decodeURIComponent(a.getAttribute('href')!.slice(1));
    if (!id || !document.getElementById(id)) return;
    e.preventDefault();
    requestAnimationFrame(() => requestAnimationFrame(() => goTo(id)));
  };
  document.addEventListener('click', onClick);

  const id = decodeURIComponent(location.hash.slice(1));
  let touched = false;
  const stop = () => (touched = true);
  if (id) {
    if ('scrollRestoration' in history) history.scrollRestoration = 'manual';
    ['wheel', 'touchstart', 'keydown', 'pointerdown'].forEach((t) => window.addEventListener(t, stop, { once: true, passive: true }));
    const land = () => {
      if (touched || !document.getElementById(id)) return;
      ScrollTrigger.refresh();
      goTo(id, { instant: true, focus: false });
    };
    const settle = () => [0, 400, 1200, 2400].forEach((ms) => window.setTimeout(land, ms));
    const ready = document.fonts ? document.fonts.ready : Promise.resolve();
    ready.then(() => (document.readyState === 'complete' ? settle() : window.addEventListener('load', settle, { once: true })));
  }

  return () => document.removeEventListener('click', onClick);
}
