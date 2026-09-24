import { useEffect, useRef, useState } from 'react';
import { DemoScreen, type ScreenOptions } from './screen';
import { Stage, type Framing } from './stage';

export interface DemoHandle {
  stage: Stage;
  screen: DemoScreen;
}

export interface DemoOptions extends ScreenOptions {
  autoplay: boolean;
  interactive: boolean;
  framing: Framing;
  eager: boolean;
  /** Recording mode: the 10 s seamless loop, plus window.__dashcastCapture for frame-exact seeking. */
  capture?: boolean;
}

/**
 * Mounts a Stage in `host` and creates its DemoScreen once the host nears the viewport. Plays only
 * while visible, the tab is shown and motion is allowed; reduced motion holds a settled still.
 */
export function useDemo(opts: DemoOptions) {
  const host = useRef<HTMLDivElement>(null);
  const [handle, setHandle] = useState<DemoHandle | null>(null);
  const first = useRef(opts);

  useEffect(() => {
    const el = host.current!;
    const o = first.current;
    const stage = new Stage(el, { framing: o.framing, eager: o.eager });
    let screen: DemoScreen | null = null;
    let visible = false;
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');

    const sync = () => {
      if (!screen) return;
      if (reduce.matches && !o.capture) {
        screen.still();
        return;
      }
      if (visible && !document.hidden && o.autoplay) screen.play();
      else screen.pause();
    };
    const create = () => {
      screen = new DemoScreen(o);
      stage.attach(screen);
      if (o.capture) {
        const s = screen;
        s.capture();
        const video = s.desk.video;
        const ready = Promise.all([
          stage.img.decode().catch(() => {}),
          document.fonts ? document.fonts.ready : null,
          new Promise((r) => (video.readyState >= 3 ? r(null) : video.addEventListener('canplaythrough', r, { once: true }))),
        ]).then(() => undefined);
        video.load();
        (window as any).__dashcastCapture = { duration: 10, ready, seek: (t: number) => s.seek(t), play: () => s.play(), pause: () => s.pause() };
      }
      setHandle({ stage, screen });
    };
    // Built a little before it scrolls in; played only while actually on screen.
    const near = new IntersectionObserver(
      (entries) => {
        if (entries[entries.length - 1].isIntersecting && !screen) {
          create();
          sync();
        }
      },
      { rootMargin: '240px 0px' },
    );
    const io = new IntersectionObserver((entries) => {
      visible = entries[entries.length - 1].isIntersecting;
      sync();
    });
    near.observe(el);
    io.observe(el);
    document.addEventListener('visibilitychange', sync);
    reduce.addEventListener('change', sync);

    let down = false;
    const point = (e: { clientX: number; clientY: number }) => {
      const r = el.getBoundingClientRect();
      return stage.toPanel(e.clientX - r.left, e.clientY - r.top);
    };
    const onDown = (e: PointerEvent) => {
      if (!screen || e.button > 0) return;
      const p = point(e);
      if (!p) return;
      down = true;
      try {
        el.setPointerCapture(e.pointerId);
      } catch {
        /* capture is best effort */
      }
      screen.touchStart(p[0], p[1]);
      if (visible && !document.hidden && !reduce.matches) screen.play();
    };
    const onMove = (e: PointerEvent) => {
      if (!down || !screen) return;
      const p = point(e);
      if (p) screen.touchMove(p[0], p[1]);
    };
    const onUp = () => {
      if (!down || !screen) return;
      down = false;
      screen.touchEnd();
    };
    const onWheel = (e: WheelEvent) => {
      if (!screen) return;
      const p = point(e);
      if (!p || !screen.wheel(p[0], p[1], e.deltaY)) return;
      e.preventDefault();
      if (visible && !document.hidden && !reduce.matches) screen.play();
    };
    if (o.interactive) {
      el.addEventListener('pointerdown', onDown);
      el.addEventListener('pointermove', onMove);
      el.addEventListener('pointerup', onUp);
      el.addEventListener('pointercancel', onUp);
      el.addEventListener('wheel', onWheel, { passive: false });
    }

    return () => {
      near.disconnect();
      io.disconnect();
      document.removeEventListener('visibilitychange', sync);
      reduce.removeEventListener('change', sync);
      el.removeEventListener('pointerdown', onDown);
      el.removeEventListener('pointermove', onMove);
      el.removeEventListener('pointerup', onUp);
      el.removeEventListener('pointercancel', onUp);
      el.removeEventListener('wheel', onWheel);
      if (o.capture) delete (window as any).__dashcastCapture;
      if (screen) (screen as DemoScreen).destroy();
      stage.destroy();
      setHandle(null);
    };
  }, []);

  return { host, handle };
}
