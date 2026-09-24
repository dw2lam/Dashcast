import { useCallback, useEffect, useRef, useState, type KeyboardEvent, type MouseEvent, type PointerEvent } from 'react';
import { ease, prefersReducedMotion } from '../lib/motion';

type Drag = { id: number; x: number; left: number; lastX: number; lastT: number; v: number; moved: boolean };

/**
 * A natively scrolling card track, tesla.com style. Trackpad, shift+wheel and touch are the browser's own
 * (touch keeps CSS mandatory snap); with a mouse or trackpad the track settles on a card in the direction of
 * travel once the gesture stops, so a short swipe pages. A mouse can also grab and fling it (momentum, then the
 * nearest card), and the click that ends a drag is swallowed. Arrow keys, Home and End step when it's focused.
 *
 * `item` selects the cards inside the track. Returns the ref and handlers to spread on the track, the edge state
 * for prev/next buttons, the current card index for dots, and step / goToIndex.
 */
export function useCarousel(item: string) {
  const track = useRef<HTMLUListElement>(null);
  const drag = useRef<Drag | null>(null);
  const raf = useRef(0);
  const gliding = useRef(false);
  const gesture = useRef<number | null>(null);
  const settleTimer = useRef(0);
  const suppressClick = useRef(false);
  const [edge, setEdge] = useState({ start: true, end: false });
  const [index, setIndex] = useState(0);

  /** Scroll positions that put each card at the start of the content column, clamped to the track. */
  const snaps = useCallback(() => {
    const t = track.current;
    if (!t) return [0];
    const cards = Array.from(t.querySelectorAll<HTMLElement>(item));
    const max = t.scrollWidth - t.clientWidth;
    const first = cards[0] ? cards[0].offsetLeft : 0;
    return cards.map((c) => Math.min(max, Math.max(0, c.offsetLeft - first)));
  }, [item]);

  const nearestIndex = useCallback(
    (x: number) => {
      const pts = snaps();
      let best = 0;
      pts.forEach((p, i) => {
        if (Math.abs(p - x) < Math.abs(pts[best] - x)) best = i;
      });
      return best;
    },
    [snaps],
  );

  const nearest = useCallback((x: number) => snaps()[nearestIndex(x)] || 0, [snaps, nearestIndex]);

  const measure = useCallback(() => {
    const t = track.current;
    if (!t) return;
    setEdge({ start: t.scrollLeft <= 2, end: t.scrollLeft + t.clientWidth >= t.scrollWidth - 2 });
    setIndex(nearestIndex(t.scrollLeft));
  }, [nearestIndex]);

  /** Tween scrollLeft (snap off meanwhile, so the browser's snapping doesn't fight the tween). */
  const glideTo = useCallback((target: number) => {
    const t = track.current;
    if (!t) return;
    cancelAnimationFrame(raf.current);
    gliding.current = false;
    const from = t.scrollLeft;
    const dist = target - from;
    if (Math.abs(dist) < 1 || prefersReducedMotion()) {
      t.scrollLeft = target;
      t.style.scrollSnapType = '';
      return;
    }
    gliding.current = true;
    t.style.scrollSnapType = 'none';
    const dur = Math.min(700, 360 + Math.abs(dist) * 0.35);
    const t0 = performance.now();
    const tick = (now: number) => {
      const k = Math.min(1, (now - t0) / dur);
      t.scrollLeft = from + dist * ease.mktg(k);
      if (k < 1) raf.current = requestAnimationFrame(tick);
      else {
        t.style.scrollSnapType = '';
        gliding.current = false;
      }
    };
    raf.current = requestAnimationFrame(tick);
  }, []);

  useEffect(() => {
    const t = track.current;
    if (!t) return;
    const begin = () => {
      if (gesture.current === null) gesture.current = t.scrollLeft;
    };
    const settle = () => {
      const start = gesture.current;
      gesture.current = null;
      if (start === null || drag.current || gliding.current) return;
      const moved = t.scrollLeft - start;
      if (Math.abs(t.scrollLeft - nearest(t.scrollLeft)) < 2) return;
      const pts = snaps();
      const pitch = pts.length > 1 ? pts[1] - pts[0] : t.clientWidth;
      glideTo(Math.abs(moved) < 24 ? nearest(start) : nearest(t.scrollLeft + Math.sign(moved) * pitch * 0.5));
    };
    const onWheel = (e: WheelEvent) => {
      if (e.shiftKey && Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
        const max = t.scrollWidth - t.clientWidth;
        const next = Math.max(0, Math.min(max, t.scrollLeft + e.deltaY));
        if (next !== t.scrollLeft) {
          e.preventDefault();
          begin();
          t.scrollLeft = next;
        }
        return;
      }
      if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) begin();
    };
    const onScroll = () => {
      measure();
      if (gesture.current === null || drag.current || gliding.current) return;
      window.clearTimeout(settleTimer.current);
      settleTimer.current = window.setTimeout(settle, 160);
    };
    measure();
    t.addEventListener('wheel', onWheel, { passive: false });
    t.addEventListener('touchstart', begin, { passive: true });
    t.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', measure);
    return () => {
      window.clearTimeout(settleTimer.current);
      cancelAnimationFrame(raf.current);
      t.removeEventListener('wheel', onWheel);
      t.removeEventListener('touchstart', begin);
      t.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', measure);
    };
  }, [snaps, nearest, glideTo, measure]);

  const goToIndex = useCallback(
    (i: number) => {
      const pts = snaps();
      glideTo(pts[Math.max(0, Math.min(pts.length - 1, i))]);
    },
    [snaps, glideTo],
  );

  const step = useCallback(
    (dir: 1 | -1) => {
      const t = track.current;
      if (t) goToIndex(nearestIndex(t.scrollLeft) + dir);
    },
    [goToIndex, nearestIndex],
  );

  const onPointerDown = (e: PointerEvent<HTMLUListElement>) => {
    if (e.pointerType !== 'mouse' || e.button !== 0) return;
    const t = track.current;
    if (!t) return;
    if ((e.target as Element).closest('a, button')) return;
    e.preventDefault();
    cancelAnimationFrame(raf.current);
    gliding.current = false;
    drag.current = { id: e.pointerId, x: e.clientX, left: t.scrollLeft, lastX: e.clientX, lastT: e.timeStamp, v: 0, moved: false };
  };

  const onPointerMove = (e: PointerEvent<HTMLUListElement>) => {
    const d = drag.current;
    const t = track.current;
    if (!d || !t || e.pointerId !== d.id) return;
    const dx = e.clientX - d.x;
    if (!d.moved) {
      if (Math.abs(dx) < 5) return;
      d.moved = true;
      t.setPointerCapture(e.pointerId);
      t.style.scrollSnapType = 'none';
      t.classList.add('is-dragging');
    }
    t.scrollLeft = d.left - dx;
    const dt = Math.max(1, e.timeStamp - d.lastT);
    d.v = 0.8 * ((e.clientX - d.lastX) / dt) + 0.2 * d.v;
    d.lastX = e.clientX;
    d.lastT = e.timeStamp;
  };

  const endDrag = (e: PointerEvent<HTMLUListElement>) => {
    const d = drag.current;
    const t = track.current;
    if (!d || !t || e.pointerId !== d.id) return;
    drag.current = null;
    if (!d.moved) return;
    if (t.hasPointerCapture(e.pointerId)) t.releasePointerCapture(e.pointerId);
    t.classList.remove('is-dragging');
    suppressClick.current = true;
    window.setTimeout(() => (suppressClick.current = false), 0);
    const idle = e.timeStamp - d.lastT > 80;
    glideTo(nearest(t.scrollLeft - (idle ? 0 : d.v * 260)));
  };

  const onKeyDown = (e: KeyboardEvent<HTMLUListElement>) => {
    const t = track.current;
    if (!t || e.target !== t) return;
    const map: Record<string, () => void> = {
      ArrowRight: () => step(1),
      ArrowLeft: () => step(-1),
      Home: () => glideTo(0),
      End: () => glideTo(t.scrollWidth - t.clientWidth),
    };
    const fn = map[e.key];
    if (!fn) return;
    e.preventDefault();
    fn();
  };

  const bind = {
    ref: track,
    tabIndex: 0,
    onPointerDown,
    onPointerMove,
    onPointerUp: endDrag,
    onPointerCancel: endDrag,
    onKeyDown,
    onDragStart: (e: MouseEvent) => e.preventDefault(),
    onClickCapture: (e: MouseEvent) => {
      if (!suppressClick.current) return;
      suppressClick.current = false;
      e.preventDefault();
      e.stopPropagation();
    },
  };

  return { bind, edge, index, step, goToIndex };
}
