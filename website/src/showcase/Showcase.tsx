import { useCallback, useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent } from 'react';
import { gsap, ScrollTrigger, ease, prefersReducedMotion, revealWithin } from '../lib/motion';
import { CHAPTERS, LAYOUTS, PAD, WINDOWS, src, type Layer, type LayoutName, type Look } from './data';
import { MenuBar } from './MenuBar';
import './showcase.css';

const LAYERS: Layer[] = ['main', 'guide', 'settings', 'panel'];
const N = CHAPTERS.length;
/** Scroll distance per chapter while the stage is pinned, in viewport heights. */
const CHAPTER_VH = 0.62;
/** Parallax drift over the whole pinned scroll, in points (nearer windows move more). */
const DEPTH: Record<Layer | 'wall', number> = { wall: 10, main: 14, guide: 26, settings: 30, panel: 8 };

function systemLook(): Look {
  try {
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  } catch {
    return 'light';
  }
}

/** Which variant of a sequence shows at `step`; the window chapter plays "waiting" once, then loops. */
function pick(seq: string[], step: number, loopFrom: number) {
  if (step < seq.length) return seq[step];
  const span = seq.length - loopFrom;
  return seq[loopFrom + ((step - loopFrom) % span)];
}

function Win({ layer, variant, loaded, u }: { layer: Layer; variant: string; loaded: Record<Look, boolean>; u: number }) {
  const spec = WINDOWS[layer];
  const box = spec.w + PAD.extra;
  const sizes = `${Math.max(1, Math.round(box * u))}px`;
  return (
    <>
      {spec.variants.map((v) =>
        (['light', 'dark'] as Look[]).map((look) =>
          loaded[look] ? (
            <img
              key={`${v.id}-${look}`}
              className={`sc__img sc__img--${look}${v.id === variant ? ' is-on' : ''}`}
              src={src(v.file, look, 1)}
              srcSet={`${src(v.file, look, 1)} ${box}w, ${src(v.file, look, 2)} ${box * 2}w`}
              sizes={sizes}
              width={box}
              height={(v.h ?? spec.h) + PAD.extra}
              alt=""
              decoding="async"
              draggable={false}
            />
          ) : null,
        ),
      )}
    </>
  );
}

export function Showcase() {
  const rootRef = useRef<HTMLElement>(null);
  const pinRef = useRef<HTMLDivElement>(null);
  const boxRef = useRef<HTMLDivElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const tabsRef = useRef<HTMLDivElement>(null);
  const tabPillRef = useRef<HTMLSpanElement>(null);
  const lookPillRef = useRef<HTMLSpanElement>(null);
  const lookRef = useRef<HTMLDivElement>(null);
  const winRefs = useRef<Partial<Record<Layer, HTMLDivElement | null>>>({});
  const pinTrigger = useRef<ScrollTrigger | null>(null);
  const entered = useRef(false);
  const shown = useRef<{ chapter: number; layout: LayoutName } | null>(null);

  const [reduced] = useState(prefersReducedMotion);
  const [look, setLook] = useState<Look>(systemLook);
  const [loaded, setLoaded] = useState<Record<Look, boolean>>(() => ({ light: false, dark: false }));
  const [chapter, setChapter] = useState(0);
  const [step, setStep] = useState(0);
  const [layout, setLayout] = useState<LayoutName>('wide');
  const [u, setU] = useState(0);
  const [inView, setInView] = useState(false);

  const spec = LAYOUTS[layout];

  // Fit the stage into whatever the pinned viewport leaves beside the header and the controls. The box is only
  // as tall as the stage, so the controls follow it directly and any spare height collects below them.
  useLayoutEffect(() => {
    const box = boxRef.current;
    const pin = pinRef.current;
    if (!box || !pin) return;
    const px = (v: string) => parseFloat(v) || 0;
    const fit = () => {
      const w = box.clientWidth;
      const pinStyle = getComputedStyle(pin);
      let h = pin.clientHeight - px(pinStyle.paddingTop) - px(pinStyle.paddingBottom);
      for (const el of Array.from(pin.children) as HTMLElement[]) {
        const s = getComputedStyle(el);
        h -= px(s.marginTop) + px(s.marginBottom) + (el === box ? 0 : el.offsetHeight);
      }
      if (!w || h <= 0) return;
      const name: LayoutName = w / h >= 1.05 ? 'wide' : 'tall';
      const l = LAYOUTS[name];
      setLayout(name);
      setU(Math.min(1.05, w / l.width, h / l.height));
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(pin);
    for (const el of Array.from(pin.children)) ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Load the visible appearance when the section comes near; the other one once it has been seen.
  useEffect(() => {
    const el = rootRef.current;
    if (!el) return;
    const near = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) setLoaded((l) => (l[look] ? l : { ...l, [look]: true }));
      },
      { rootMargin: '150% 0px' },
    );
    const visible = new IntersectionObserver(([entry]) => setInView(entry.isIntersecting), { threshold: 0.15 });
    near.observe(el);
    visible.observe(el);
    return () => {
      near.disconnect();
      visible.disconnect();
    };
  }, [look]);

  useEffect(() => {
    if (!inView) return;
    const t = window.setTimeout(() => setLoaded({ light: true, dark: true }), 2500);
    return () => window.clearTimeout(t);
  }, [inView]);

  const chapterRef = useRef(chapter);
  const layoutRef = useRef(layout);
  const uRef = useRef(u);
  chapterRef.current = chapter;
  layoutRef.current = layout;
  uRef.current = u;

  /** Moves every window to where chapter `k` wants it: slide in, slide out, or glide. */
  const place = useCallback((k: number, name: LayoutName, instant: boolean) => {
    const places = LAYOUTS[name].places;
    for (const layer of LAYERS) {
      const el = winRefs.current[layer];
      if (!el) continue;
      const p = places[layer][k];
      const wasOn = el.dataset.on === '1';
      el.dataset.on = p.on ? '1' : '0';
      gsap.killTweensOf(el);
      const clip = layer === 'panel' ? { clipPath: p.on ? 'inset(0% 0% 0% 0%)' : 'inset(0% 0% 100% 0%)' } : {};
      if (instant) {
        gsap.set(el, { '--x': p.x, '--y': p.y, autoAlpha: p.on ? 1 : 0, ...clip });
      } else if (p.on && !wasOn) {
        const delay = layer === 'main' ? 0 : 0.12;
        gsap.to(el, { '--x': p.x, '--y': p.y, duration: 1.1, ease: ease.mktg, delay });
        // Opaque quickly (a see-through window reads as a ghost); the glide carries the motion.
        gsap.to(el, { autoAlpha: 1, duration: layer === 'panel' ? 0.25 : 0.4, ease: ease.mktg, delay });
        if (layer === 'panel') gsap.to(el, { ...clip, duration: 0.9, ease: ease.mktg, delay });
      } else if (!p.on && wasOn) {
        gsap.to(el, { '--x': p.x, '--y': p.y, autoAlpha: 0, duration: 0.5, ease: ease.tds, ...clip });
      } else if (p.on) {
        // Also finishes a fade or reveal a quick scroll may have cut short.
        gsap.to(el, { '--x': p.x, '--y': p.y, duration: 1.1, ease: ease.slide });
        gsap.to(el, { autoAlpha: 1, duration: 0.4, ease: ease.mktg });
        if (layer === 'panel') gsap.to(el, { ...clip, duration: 0.9, ease: ease.mktg });
      } else {
        gsap.set(el, { '--x': p.x, '--y': p.y, autoAlpha: 0, ...clip });
      }
    }
    shown.current = { chapter: k, layout: name };
  }, []);

  /** Before the section arrives: every window waits, hidden, where it will come in from. */
  const park = useCallback((name: LayoutName) => {
    const places = LAYOUTS[name].places;
    for (const layer of LAYERS) {
      const el = winRefs.current[layer];
      if (!el) continue;
      const p = places[layer][0];
      el.dataset.on = '0';
      gsap.set(el, {
        '--x': p.x,
        '--y': p.y + (layer === 'main' ? 64 : 0),
        autoAlpha: 0,
        ...(layer === 'panel' ? { clipPath: 'inset(0% 0% 100% 0%)' } : {}),
      });
    }
  }, []);

  useLayoutEffect(() => {
    if (!u) return;
    if (reduced) entered.current = true;
    if (!entered.current) return park(layout);
    const last = shown.current;
    if (last && last.chapter === chapter && last.layout === layout) return;
    place(chapter, layout, reduced || !last || last.layout !== layout);
  }, [chapter, layout, u, reduced, place, park]);

  // Scroll: the stage wipes open as the section rises, then pins while the chapters play.
  const ready = u > 0;
  useEffect(() => {
    const root = rootRef.current;
    const pin = pinRef.current;
    const stage = stageRef.current;
    if (!root || !pin || !stage || !ready) return;
    const undoReveal = revealWithin(root);
    if (reduced) return undoReveal;

    const navHeight = () => parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--nav-h')) || 56;
    const pinLength = () => `+=${Math.round(window.innerHeight * CHAPTER_VH * N)}`;
    const ctx = gsap.context(() => {
      const rise = { trigger: root, start: 'top 92%', end: 'top 8%', scrub: 0.6 };
      // The top edge stays put under the subtitle; the stage opens from the sides and the bottom.
      gsap.fromTo(stage, { clipPath: 'inset(0% 7% 9% 7% round 16px)' },
        { clipPath: 'inset(0% 0% 0% 0% round 8px)', ease: 'none', scrollTrigger: rise });
      gsap.fromTo('.sc__walls', { scale: 1.14 }, { scale: 1, ease: 'none', scrollTrigger: rise });
      gsap.fromTo('.sc__bar', { yPercent: -100, autoAlpha: 0 },
        { yPercent: 0, autoAlpha: 1, ease: 'none', scrollTrigger: { ...rise, start: 'top 50%', end: 'top 20%' } });

      ScrollTrigger.create({
        trigger: root,
        start: 'top 42%',
        once: true,
        onEnter: () => {
          entered.current = true;
          place(chapterRef.current, layoutRef.current, false);
        },
      });

      pinTrigger.current = ScrollTrigger.create({
        trigger: pin,
        start: () => `top ${navHeight()}px`,
        end: pinLength,
        pin: true,
        anticipatePin: 1,
        invalidateOnRefresh: true,
        onUpdate: (self) => setChapter(Math.min(N - 1, Math.floor(self.progress * N))),
      });

      const drift = { trigger: pin, start: () => `top ${navHeight()}px`, end: pinLength, scrub: 0.8, invalidateOnRefresh: true };
      gsap.fromTo('.sc__walls', { y: 0 }, { y: () => -DEPTH.wall * uRef.current, ease: 'none', scrollTrigger: drift });
      for (const layer of LAYERS) {
        gsap.fromTo(`.sc__win--${layer} .sc__par`, { y: 0 },
          { y: () => -DEPTH[layer] * uRef.current, ease: 'none', scrollTrigger: drift });
      }
    }, root);

    return () => {
      pinTrigger.current = null;
      ctx.revert();
      undoReveal();
    };
  }, [reduced, ready, place]);

  // Each chapter restarts its little loop: waiting → casting → mirror…, setup pages, settings tabs.
  useEffect(() => setStep(0), [chapter]);
  useEffect(() => {
    if (reduced || !inView) return;
    const ch = CHAPTERS[chapter];
    const length = Math.max(ch.main.length, ch.settings?.length ?? 1);
    if (length < 2) return;
    const current = pick(ch.main, step, chapter === 0 ? 1 : 0);
    const t = window.setTimeout(() => setStep((s) => s + 1), current === 'waiting' ? 1700 : 2800);
    return () => window.clearTimeout(t);
  }, [chapter, step, inView, reduced]);

  const ch = CHAPTERS[chapter];
  const still = reduced ? (chapter === 0 ? 1 : 0) : step;
  const mainVariant = pick(ch.main, still, chapter === 0 ? 1 : 0);
  const settingsVariant = ch.settings ? pick(ch.settings, still, 0) : 'general';

  // Sliding pills under the selected tab and the selected appearance.
  const movePill = useCallback((track: HTMLElement | null, pill: HTMLElement | null) => {
    const btn = track?.querySelector<HTMLElement>('[aria-selected="true"], [aria-pressed="true"]');
    if (!pill || !btn) return;
    pill.style.width = `${btn.offsetWidth}px`;
    pill.style.transform = `translateX(${btn.offsetLeft}px)`;
  }, []);
  useLayoutEffect(() => movePill(tabsRef.current, tabPillRef.current), [chapter, u, movePill]);
  useLayoutEffect(() => movePill(lookRef.current, lookPillRef.current), [look, u, movePill]);

  const go = (k: number) => {
    const st = pinTrigger.current;
    if (st) {
      const y = st.start + ((k + 0.5) / N) * (st.end - st.start);
      window.scrollTo({ top: Math.round(y), behavior: reduced ? 'auto' : 'smooth' });
    } else {
      setChapter(k);
    }
  };

  const onTabKey = (e: KeyboardEvent<HTMLDivElement>) => {
    const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
    if (!d) return;
    e.preventDefault();
    const k = (chapter + d + N) % N;
    go(k);
    tabsRef.current?.querySelectorAll<HTMLElement>('[role="tab"]')[k]?.focus();
  };

  const chooseLook = (next: Look) => {
    setLoaded((l) => (l[next] ? l : { ...l, [next]: true }));
    setLook(next);
  };

  return (
    <section id="app" ref={rootRef} className={`sc section${reduced ? ' sc--still' : ''}`} aria-labelledby="app-title">
      <div className="sc__pin" ref={pinRef}>
        <header className="sc__head wrap section-head">
          <h2 id="app-title" className="t-section" data-reveal="large">
            The Mac app
          </h2>
          <p className="t-sub" data-reveal="small" data-reveal-delay="0.1">
            One glass window. Nothing in the way.
          </p>
        </header>

        <div className="sc__box" ref={boxRef}>
          <div
            className="sc__stage"
            ref={stageRef}
            data-look={look}
            role="img"
            aria-label={`Dashcast on macOS, ${look} appearance: ${ch.caption}`}
            style={{
              width: `${Math.round(spec.width * u)}px`,
              height: `${Math.round(spec.height * u)}px`,
              ['--u' as string]: u,
              visibility: u ? undefined : 'hidden',
            }}
          >
            <div className="sc__walls" aria-hidden="true">
              {loaded.light || look === 'light' ? (
                <img className="sc__wall" src="/shots/wallpaper-light-1280.jpg"
                  srcSet="/shots/wallpaper-light-1280.jpg 1280w, /shots/wallpaper-light.jpg 2560w"
                  sizes={`${Math.round(spec.width * u)}px`} alt="" />
              ) : null}
              {loaded.dark || look === 'dark' ? (
                <img className="sc__wall sc__wall--dark" src="/shots/wallpaper-1280.jpg"
                  srcSet="/shots/wallpaper-1280.jpg 1280w, /shots/wallpaper.jpg 2560w"
                  sizes={`${Math.round(spec.width * u)}px`} alt="" />
              ) : null}
            </div>

            {LAYERS.map((layer) => {
              const w = WINDOWS[layer];
              return (
                <div
                  key={layer}
                  className={`sc__win sc__win--${layer}`}
                  ref={(el) => {
                    winRefs.current[layer] = el;
                  }}
                  style={{ ['--w' as string]: w.w + PAD.extra, ['--h' as string]: w.h + PAD.extra }}
                >
                  <div className="sc__par">
                    <Win
                      layer={layer}
                      loaded={loaded}
                      u={u}
                      variant={layer === 'main' ? mainVariant : layer === 'settings' ? settingsVariant : WINDOWS[layer].variants[0].id}
                    />
                  </div>
                </div>
              );
            })}

            <MenuBar layout={layout} open={chapter === 1} />
          </div>
        </div>

        <div className="sc__controls">
          <div className="sc__tabs" role="tablist" aria-label="Screens" ref={tabsRef} onKeyDown={onTabKey}>
            <span className="sc__pill" ref={tabPillRef} aria-hidden="true" />
            {CHAPTERS.map((c, k) => (
              <button key={c.id} type="button" role="tab" className="sc__tab" aria-selected={k === chapter}
                tabIndex={k === chapter ? 0 : -1} onClick={() => go(k)}>
                {c.tab}
              </button>
            ))}
          </div>
          <div className="sc__look" role="group" aria-label="Appearance" ref={lookRef}>
            <span className="sc__pill" ref={lookPillRef} aria-hidden="true" />
            {(['light', 'dark'] as Look[]).map((l) => (
              <button key={l} type="button" className="sc__lookbtn" aria-pressed={look === l} onClick={() => chooseLook(l)}>
                {l === 'light' ? 'Light' : 'Dark'}
              </button>
            ))}
          </div>
          <p className="sc__caption" key={ch.id} aria-live="polite">
            {ch.caption}
          </p>
        </div>
      </div>
    </section>
  );
}
