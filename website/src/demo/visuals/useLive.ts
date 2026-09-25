import { useEffect, useRef } from 'react';

export interface LiveHandlers {
  /** Called once, the first time the element comes near the viewport. */
  init(el: HTMLDivElement): void;
  /** Visible, tab shown and motion allowed. */
  play(): void;
  pause(): void;
  /** prefers-reduced-motion: hold a static frame. */
  still(): void;
  destroy(): void;
}

/** Drives a visual: built lazily near the viewport, animated only while seen and allowed to move. */
export function useLive(make: () => LiveHandlers) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = ref.current!;
    const h = make();
    let built = false;
    let visible = false;
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
    const sync = () => {
      if (!built) return;
      if (reduce.matches) h.still();
      else if (visible && !document.hidden) h.play();
      else h.pause();
    };
    const near = new IntersectionObserver(
      (e) => {
        if (!built && e[e.length - 1].isIntersecting) {
          built = true;
          h.init(el);
          sync();
        }
      },
      { rootMargin: '300px' },
    );
    const io = new IntersectionObserver((e) => {
      visible = e[e.length - 1].isIntersecting;
      sync();
    });
    near.observe(el);
    io.observe(el);
    document.addEventListener('visibilitychange', sync);
    reduce.addEventListener('change', sync);
    return () => {
      near.disconnect();
      io.disconnect();
      document.removeEventListener('visibilitychange', sync);
      reduce.removeEventListener('change', sync);
      if (built) h.destroy();
    };
  }, []);
  return ref;
}
