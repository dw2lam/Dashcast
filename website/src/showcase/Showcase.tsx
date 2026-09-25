import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { gsap, ease, prefersReducedMotion } from '../lib/motion';
import { Segmented } from '../ui/Segmented';
import { MediaRow, type Stat } from '../sections/MediaRow';
import { CHAPTERS, LAYOUTS, PAD, WINDOWS, src, type Layer, type Look } from './data';
import { MenuBar } from './MenuBar';
import './showcase.css';

const LAYERS: Layer[] = ['main', 'guide', 'settings', 'panel'];
const N = CHAPTERS.length;
/** The stage is always the 16:10 desktop, the same box as the car screen above it. */
const SPEC = LAYOUTS.wide;
/** How long each chapter stays up before the next one, while nobody has touched the controls. */
const CHAPTER_MS = 7000;

const STATS: Stat[] = [
  { value: '1', unit: 'window', label: 'Start, stop, your car live', icon: 'window' },
  { value: '3', unit: 'steps', label: 'set up once', icon: 'steps' },
];

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

/**
 * #app: native captures of the Mac app on a small 16:10 desktop, as the media of the same "media + content row"
 * as the demo above it. The chapters switch from the tabs, or advance by themselves while the section is on
 * screen and nobody has picked one; the windows glide between places with Tesla's easing.
 */
export function Showcase() {
  const rootRef = useRef<HTMLElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const winRefs = useRef<Partial<Record<Layer, HTMLDivElement | null>>>({});
  const entered = useRef(false);
  const shown = useRef<number | null>(null);

  const [reduced] = useState(prefersReducedMotion);
  const [look, setLook] = useState<Look>(systemLook);
  const [loaded, setLoaded] = useState<Record<Look, boolean>>(() => ({ light: false, dark: false }));
  const [chapter, setChapter] = useState(0);
  const [step, setStep] = useState(0);
  const [u, setU] = useState(0);
  const [inView, setInView] = useState(false);
  const [picked, setPicked] = useState(false);

  // One point of the desktop in CSS px: the stage fills its 16:10 box.
  useLayoutEffect(() => {
    const stage = stageRef.current;
    if (!stage) return;
    const fit = () => {
      const w = stage.clientWidth;
      if (w) setU(Math.min(1.05, w / SPEC.width));
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(stage);
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
    const visible = new IntersectionObserver(([entry]) => setInView(entry.isIntersecting), { threshold: 0.3 });
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

  /** Moves every window to where chapter `k` wants it: slide in, slide out, or glide. */
  const place = useCallback((k: number, instant: boolean) => {
    const places = SPEC.places;
    for (const layer of LAYERS) {
      const el = winRefs.current[layer];
      if (!el) continue;
      const p = places[layer][k];
      const wasOn = el.dataset.on === '1';
      el.dataset.on = p.on ? '1' : '0';
      gsap.killTweensOf(el);
      if (instant) {
        gsap.set(el, { '--x': p.x, '--y': p.y, autoAlpha: p.on ? 1 : 0 });
      } else if (p.on && !wasOn) {
        const delay = layer === 'main' ? 0 : 0.1;
        gsap.to(el, { '--x': p.x, '--y': p.y, duration: 0.9, ease: ease.mktg, delay });
        gsap.to(el, { autoAlpha: 1, duration: 0.5, ease: ease.mktg, delay });
      } else if (!p.on && wasOn) {
        gsap.to(el, { '--x': p.x, '--y': p.y, autoAlpha: 0, duration: 0.5, ease: ease.tds });
      } else if (p.on) {
        gsap.to(el, { '--x': p.x, '--y': p.y, duration: 0.9, ease: ease.slide });
        gsap.to(el, { autoAlpha: 1, duration: 0.4, ease: ease.mktg });
      } else {
        gsap.set(el, { '--x': p.x, '--y': p.y, autoAlpha: 0 });
      }
    }
    shown.current = k;
  }, []);

  /** Before the section is seen: every window waits, hidden, a little below where it will settle. */
  const park = useCallback(() => {
    for (const layer of LAYERS) {
      const el = winRefs.current[layer];
      if (!el) continue;
      const p = SPEC.places[layer][0];
      el.dataset.on = '0';
      gsap.set(el, { '--x': p.x, '--y': p.y + (layer === 'main' ? 24 : 0), autoAlpha: 0 });
    }
  }, []);

  useLayoutEffect(() => {
    if (!u) return;
    if (reduced) entered.current = true;
    if (!entered.current) return park();
    if (shown.current === chapter) return;
    place(chapter, reduced || shown.current === null);
  }, [chapter, u, reduced, place, park]);

  // The first time the stage is on screen the windows settle into place.
  useEffect(() => {
    if (!inView || entered.current || !u) return;
    entered.current = true;
    place(chapter, false);
  }, [inView, u, chapter, place]);

  useEffect(() => () => {
    for (const layer of LAYERS) {
      const el = winRefs.current[layer];
      if (el) gsap.killTweensOf(el);
    }
  }, []);

  // Chapters advance by themselves until someone picks one.
  useEffect(() => {
    if (reduced || !inView || picked) return;
    const t = window.setTimeout(() => setChapter((c) => (c + 1) % N), CHAPTER_MS);
    return () => window.clearTimeout(t);
  }, [chapter, inView, picked, reduced]);

  // Each chapter restarts its little loop: waiting → casting → mirror…, setup pages, settings tabs.
  useEffect(() => setStep(0), [chapter]);
  useEffect(() => {
    if (reduced || !inView) return;
    const ch = CHAPTERS[chapter];
    const length = Math.max(ch.main.length, ch.settings?.length ?? 1);
    if (length < 2) return;
    const current = pick(ch.main, step, chapter === 0 ? 1 : 0);
    const t = window.setTimeout(() => setStep((s) => s + 1), current === 'waiting' ? 1700 : 2400);
    return () => window.clearTimeout(t);
  }, [chapter, step, inView, reduced]);

  const ch = CHAPTERS[chapter];
  const still = reduced ? (chapter === 0 ? 1 : 0) : step;
  const mainVariant = pick(ch.main, still, chapter === 0 ? 1 : 0);
  const settingsVariant = ch.settings ? pick(ch.settings, still, 0) : 'general';

  const chooseChapter = (id: string) => {
    setPicked(true);
    setChapter(Math.max(0, CHAPTERS.findIndex((c) => c.id === id)));
  };

  const chooseLook = (next: Look) => {
    setLoaded((l) => (l[next] ? l : { ...l, [next]: true }));
    setLook(next);
  };

  const stage = (
    <div
      className="sc__stage"
      id="app-stage"
      ref={stageRef}
      data-look={look}
      role="img"
      aria-label={`Dashcast on macOS, ${look} appearance: ${ch.caption}`}
      style={{ ['--u' as string]: u, visibility: u ? undefined : 'hidden' }}
    >
      <div className="sc__walls" aria-hidden="true">
        {loaded.light || look === 'light' ? (
          <img className="sc__wall" src="/shots/wallpaper-light-1280.jpg"
            srcSet="/shots/wallpaper-light-1280.jpg 1280w, /shots/wallpaper-light.jpg 2560w"
            sizes={`${Math.round(SPEC.width * u)}px`} alt="" />
        ) : null}
        {loaded.dark || look === 'dark' ? (
          <img className="sc__wall sc__wall--dark" src="/shots/wallpaper-1280.jpg"
            srcSet="/shots/wallpaper-1280.jpg 1280w, /shots/wallpaper.jpg 2560w"
            sizes={`${Math.round(SPEC.width * u)}px`} alt="" />
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
            <Win
              layer={layer}
              loaded={loaded}
              u={u}
              variant={layer === 'main' ? mainVariant : layer === 'settings' ? settingsVariant : WINDOWS[layer].variants[0].id}
            />
          </div>
        );
      })}

      <MenuBar layout="wide" open={chapter === 1} />
    </div>
  );

  return (
    <MediaRow
      id="app"
      className={`app-row${reduced ? ' sc--still' : ''}`}
      sectionRef={rootRef}
      title="The Mac app"
      sub="One glass window. Nothing in the way."
      media={stage}
      controls={
        <>
          <Segmented
            label="Screens"
            semantics="tablist"
            controls="app-stage"
            idPrefix="app-tab"
            className="app-row__tabs"
            items={CHAPTERS.map((c) => ({ id: c.id, label: c.tab }))}
            value={ch.id}
            onChange={chooseChapter}
          />
          <Segmented
            label="Appearance"
            items={[
              { id: 'light', label: 'Light' },
              { id: 'dark', label: 'Dark' },
            ]}
            value={look}
            onChange={(v) => chooseLook(v as Look)}
          />
        </>
      }
      caption={ch.caption}
      note="macOS 15 or later · Apple silicon"
      stats={STATS}
    />
  );
}
