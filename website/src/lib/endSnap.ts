import { gsap, ease, prefersReducedMotion } from './motion';
import { isNavigating } from './navigate';

/**
 * Snaps the page into the closing section once, when a downward scroll settles within reach of the end.
 * A one-way JS snap rather than CSS scroll-snap: a snap point at the very end of the page would pull a
 * short scroll-up straight back down, and the reader would be stuck on the finale.
 */
export function installEndSnap(): () => void {
  let lastY = window.scrollY;
  let downward = false;
  let timer = 0;
  let touching = false;
  let snapping: gsap.core.Tween | null = null;

  const reach = () => Math.min(360, window.innerHeight * 0.4);

  const settle = () => {
    timer = 0;
    if (touching || isNavigating() || (snapping && snapping.isActive())) return;
    const max = document.documentElement.scrollHeight - window.innerHeight;
    const remaining = max - window.scrollY;
    if (!downward || remaining <= 1 || remaining > reach()) return;
    if (prefersReducedMotion()) {
      window.scrollTo(0, max);
      return;
    }
    snapping = gsap.to(window, { scrollTo: { y: max, autoKill: true }, duration: 0.5, ease: ease.tds, overwrite: true });
  };

  const onScroll = () => {
    const y = window.scrollY;
    if (Math.abs(y - lastY) > 0.5) downward = y > lastY;
    lastY = y;
    if (timer) window.clearTimeout(timer);
    timer = window.setTimeout(settle, 140);
  };
  const onTouchStart = () => {
    touching = true;
  };
  const onTouchEnd = () => {
    touching = false;
    onScroll();
  };

  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('touchstart', onTouchStart, { passive: true });
  window.addEventListener('touchend', onTouchEnd, { passive: true });
  window.addEventListener('touchcancel', onTouchEnd, { passive: true });
  return () => {
    window.removeEventListener('scroll', onScroll);
    window.removeEventListener('touchstart', onTouchStart);
    window.removeEventListener('touchend', onTouchEnd);
    window.removeEventListener('touchcancel', onTouchEnd);
    if (timer) window.clearTimeout(timer);
    snapping?.kill();
  };
}
