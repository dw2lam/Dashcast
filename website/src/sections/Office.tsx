import { ASSET_V } from '../lib/links';
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type SyntheticEvent } from 'react';
import { gsap, ease, prefersReducedMotion } from '../lib/motion';
import { Band } from './Band';
import './Office.css';

const STEPS = [
  { title: 'Swivel the screen', body: 'Optional: a third-party swivel mount turns the display toward you.' },
  { title: 'Lift out the trunk floor', body: 'The rear trunk’s subfloor cover comes right out.' },
  {
    title: 'Make a desk',
    body: 'Slide it under the wheel, below the screen; the wheel holds it in place. Your MacBook sits on the passenger side.',
  },
];

/*
 * The composite, on the office photo (Bram Van Oost, Unsplash) cropped to 2700×1460 px:
 * research/office/prep_office.py (grade, screen fit) and render_macbook.py (the board and the MacBook,
 * rendered in Blender through the photo's own fitted camera, then graded and grained into it).
 */
const W = 2700;
const H = 1460;
type P2 = [number, number];
/** The screen's active area in the crop (edge-fitted, pixel edges). */
const ACTIVE: P2[] = [
  [1083.92, 180.83],
  [1584.52, 187.64],
  [1581.19, 499.52],
  [1079.95, 502.9],
];
/** The live picture overlaps the bezel by this much (crop px), so its edge never shows a gap. */
const OUTSET = 0.75;
/** The rendered sprites' places in the crop (x, y, w, h), from prep_office.py. */
const BOARD_SPRITE = [443, 627, 1989, 340];
const MAC_SPRITE = [1274, 269, 1147, 556];
/** The steering wheel in the photo (crop px): its rim and lower spoke are drawn back over the board. */
const RIM = { cx: 670, cy: 370, rx: 312, ry: 291 };
const RIM_T = 45;
const ellipsePath = (cx: number, cy: number, rx: number, ry: number) => `M${cx - rx} ${cy} a${rx} ${ry} 0 1 0 ${2 * rx} 0 a${rx} ${ry} 0 1 0 ${-2 * rx} 0 Z`;
const RIM_RING = ellipsePath(RIM.cx, RIM.cy, RIM.rx, RIM.ry) + ' ' + ellipsePath(RIM.cx, RIM.cy, RIM.rx - RIM_T, RIM.ry - RIM_T);
const BASE = '/demo/';

/** CSS matrix3d that maps a w×h box onto the quad (TL, TR, BR, BL). */
function quadMatrix(w: number, h: number, q: P2[]) {
  const [[x0, y0], [x1, y1], [x2, y2], [x3, y3]] = q;
  const dx1 = x1 - x2;
  const dx2 = x3 - x2;
  const dx3 = x0 - x1 + x2 - x3;
  const dy1 = y1 - y2;
  const dy2 = y3 - y2;
  const dy3 = y0 - y1 + y2 - y3;
  const den = dx1 * dy2 - dx2 * dy1;
  const g = (dx3 * dy2 - dx2 * dy3) / den;
  const hh = (dx1 * dy3 - dx3 * dy1) / den;
  const a = x1 - x0 + g * x1;
  const b = x3 - x0 + hh * x3;
  const d = y1 - y0 + g * y1;
  const e = y3 - y0 + hh * y3;
  return `matrix3d(${[a / w, d / w, 0, g / w, b / h, e / h, 0, hh / h, 0, 0, 1, 0, x0, y0, 0, 1].map((n) => +n.toPrecision(10)).join(',')})`;
}

/** A quad pushed out by d px along each side (for a quad this close to a rectangle, per corner along the diagonal). */
function outset(q: P2[], d: number): P2[] {
  const cx = q.reduce((t, p) => t + p[0], 0) / 4;
  const cy = q.reduce((t, p) => t + p[1], 0) / 4;
  return q.map(([x, y]) => [x + Math.sign(x - cx) * d, y + Math.sign(y - cy) * d] as P2);
}

interface Pose {
  board: number;
  mac: number;
  mirror: number;
}

/**
 * Where each step leaves the scene. The swivel mount is optional and, from this seat, a 12–15° turn moves the
 * screen's edge by ~15 of 2700 px: step 1 keeps the photo untouched and lets its text say it.
 */
const POSES: Pose[] = [
  { board: 0, mac: 0, mirror: 0 },
  { board: 1, mac: 0, mirror: 0 },
  { board: 1, mac: 1, mirror: 1 },
];
const OPENING: Pose = { board: 0, mac: 0, mirror: 0 };

/** How long each step stays up before the next, while nobody has picked one. */
const STEP_MS = 2800;

/**
 * "Your office, anywhere" as one dark passage in /powerwall's layout: the heading, then the composite across the
 * content column (a real Model 3 cabin by Bram Van Oost on Unsplash, with the setup drawn into it in the photo's
 * own perspective: the trunk's subfloor cover slides in under the wheel,
 * and a MacBook sits on its passenger end with the car's screen as its second display), the three steps as
 * columns under it with the active one white, and the band's photo rising out of the same black with the story's
 * closing line. Each step animates in 0.7 s; the steps advance while the section is on screen, until someone
 * picks one.
 */
export function Office() {
  const root = useRef<HTMLElement>(null);
  const photo = useRef<HTMLDivElement>(null);
  const world = useRef<HTMLDivElement>(null);
  const [reduced] = useState(prefersReducedMotion);
  const [active, setActive] = useState(reduced ? STEPS.length - 1 : 0);
  const [inView, setInView] = useState(false);
  const [picked, setPicked] = useState(false);
  const pose = useRef<Pose>({ ...(reduced ? POSES[2] : OPENING) });
  const shown = useRef(reduced ? STEPS.length - 1 : -1);

  /** Draws the current pose. The board slides in from the passenger side, under the rim. */
  const draw = useCallback(() => {
    const w = world.current;
    if (!w) return;
    const p = pose.current;
    const q = (s: string) => w.querySelector(s) as HTMLElement;
    q('.o-desk').style.opacity = String(p.mirror);
    const board = q('.o-board-img');
    board.style.opacity = String(Math.min(1, p.board * 2));
    board.style.transform = `translate(${BOARD_SPRITE[0] + (1 - p.board) * 900}px, ${BOARD_SPRITE[1]}px)`;
    const mac = q('.o-mac-img');
    mac.style.opacity = String(p.mac);
    mac.style.transform = `translate(${MAC_SPRITE[0]}px, ${MAC_SPRITE[1] - (1 - p.mac) * 60}px)`;
  }, []);

  /** Goes to step k: every earlier step already done, step k itself animated in. */
  const show = useCallback(
    (k: number) => {
      const p = pose.current;
      gsap.killTweensOf(p);
      const to = POSES[k];
      if (reduced) {
        Object.assign(p, to);
        draw();
        shown.current = k;
        return;
      }
      const t = gsap.timeline({ onUpdate: draw });
      if (k === 0) {
        t.to(p, { board: 0, mac: 0, mirror: 0, duration: 0.5, ease: ease.tds }, 0);
      } else if (k === 1) {
        t.to(p, { mac: 0, mirror: 0, duration: 0.3, ease: ease.tds }, 0);
        t.to(p, { board: 1, duration: 0.7, ease: ease.mktg }, 0);
      } else {
        t.to(p, { board: 1, duration: 0.4, ease: ease.mktg }, 0);
        t.to(p, { mac: 1, duration: 0.6, ease: ease.mktg }, 0.05);
        t.to(p, { mirror: 1, duration: 0.55, ease: ease.tds }, 0.15);
      }
      shown.current = k;
    },
    [draw, reduced],
  );

  // Fit the model's 2700×1460 px space to the photo box; draw the opening frame before the first paint.
  useLayoutEffect(() => {
    const box = photo.current;
    const w = world.current;
    if (!box || !w) return;
    const fit = () => (w.style.transform = `scale(${box.clientWidth / W})`);
    fit();
    draw();
    const ro = new ResizeObserver(fit);
    ro.observe(box);
    return () => ro.disconnect();
  }, [draw]);

  useEffect(() => {
    const el = root.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => setInView(e.isIntersecting), { threshold: 0.35 });
    io.observe(el);
    return () => io.disconnect();
  }, []);

  useEffect(() => {
    if (reduced) return;
    if (!inView && shown.current === -1) return;
    if (shown.current !== active) show(active);
  }, [active, inView, show, reduced]);

  useEffect(() => {
    if (reduced || !inView || picked) return;
    const t = window.setTimeout(() => setActive((a) => (a + 1) % STEPS.length), STEP_MS);
    return () => window.clearTimeout(t);
  }, [active, inView, picked, reduced]);

  useEffect(() => {
    const p = pose.current;
    return () => {
      gsap.killTweensOf(p);
    };
  }, []);

  const choose = (i: number) => {
    setPicked(true);
    if (reduced) {
      setActive(i);
      show(i);
      return;
    }
    if (i === active && shown.current === i) show(i);
    setActive(i);
  };

  /** The rim is redrawn from the photo itself, so use whichever size the browser picked for the base. */
  const onPhoto = (e: SyntheticEvent<HTMLImageElement>) => {
    const img = e.currentTarget;
    world.current?.querySelectorAll('.o-rim').forEach((r) => r.setAttribute('href', img.currentSrc || img.src));
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

        <div className="office__art">
          <div
            className="office__photo"
            ref={photo}
            role="img"
            aria-label="A Tesla Model 3 cabin seen from the back seat: the centre screen turned toward the passenger, a board across the front under the steering wheel, and a MacBook on it."
          >
            <img
              className="office__base"
              src={BASE + 'office-1400.webp' + ASSET_V}
              srcSet={`${BASE}office-1400.webp${ASSET_V} 1400w, ${BASE}office-2000.webp${ASSET_V} 2000w, ${BASE}office-2700.webp${ASSET_V} 2700w`}
              sizes="(max-width: 1247px) 100vw, 1200px"
              alt=""
              decoding="async"
              onLoad={onPhoto}
            />
            <div className="o-world" ref={world} aria-hidden="true">
              <div className="o-desk" style={{ transform: quadMatrix(1000, 625, outset(ACTIVE, OUTSET)) }} />
              <img className="o-board-img" src={BASE + 'office-board.webp' + ASSET_V} width={BOARD_SPRITE[2]} height={BOARD_SPRITE[3]} alt="" loading="lazy" decoding="async" />
              <svg className="o-over" viewBox={`0 0 ${W} ${H}`} width={W} height={H}>
                <defs>
                  {/* What of the wheel is in front of the board: the rim (an annulus) and the lower spoke, as two
                      clips (one clip with both would even-odd away their overlap). */}
                  <clipPath id="office-rim">
                    <path clipRule="evenodd" d={RIM_RING} />
                  </clipPath>
                  <clipPath id="office-spoke">
                    <polygon points="607,517 737,517 708,640 612,640" />
                  </clipPath>
                </defs>
                <image className="o-rim" href={BASE + 'office-1400.webp' + ASSET_V} x="0" y="0" width={W} height={H} clipPath="url(#office-rim)" preserveAspectRatio="none" />
                <image className="o-rim" href={BASE + 'office-1400.webp' + ASSET_V} x="0" y="0" width={W} height={H} clipPath="url(#office-spoke)" preserveAspectRatio="none" />
              </svg>
              <img className="o-mac-img" src={BASE + 'office-macbook.webp' + ASSET_V} width={MAC_SPRITE[2]} height={MAC_SPRITE[3]} alt="" loading="lazy" decoding="async" />
            </div>
          </div>
        </div>

        <ol className="office__steps">
          {STEPS.map((s, i) => {
            const on = i === active;
            return (
              <li key={s.title} className={on ? 'is-on' : undefined}>
                <button type="button" className="office__step" aria-current={on ? 'step' : undefined} onClick={() => choose(i)}>
                  <span className="office__title">{s.title}</span>
                  <span className="office__body">{s.body}</span>
                </button>
              </li>
            );
          })}
        </ol>

        <p className="office__note">
          Our setup, in a Model 3/Y. Parked only. Take the board out before you drive.
          <span className="office__credit">MacBook model: jackbaeten, CC BY 4.0.</span>
        </p>
      </div>

      <Band />
    </section>
  );
}
