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
 * The explainer is drawn in the photo's own perspective (research/office/prep_office.py): a level pinhole
 * down the car's axis, f = 2000 px, principal point (1490, 690) in the original 3000×2000 photo; HC maps
 * the model onto the measured screen. Car frame: x → passenger, y ↓, z → forward, metres from the camera.
 */
const F = 2000;
const CX = 1490;
const CY = 690;
const CROP = [150, 560];
const W = 2700;
const H = 1460;
const HC = [
  [1.014632772, -0.016919271, 0.529699802],
  [0.018615382, 0.997630216, -21.668737224],
  [6.327e-6, -5.545e-6, 1],
];
const SCREEN = { c: [-0.00535, 0.14686, 1.37462], w: 0.368, h: 0.24153, depth: 0.026 };
const TEX = [1072, 704];
const TURN = (30 * Math.PI) / 180;
const BOARD = { x0: -0.55, x1: 0.55, z0: 1.0, z1: 1.42, y: 0.335, t: 0.013 };
const MAC = { x0: 0.21, x1: 0.522, zf: 1.07, zh: 1.29, base: 0.0155, lid: 0.215, lean: (20 * Math.PI) / 180 };
/** The steering wheel's rim in the photo (crop px): drawn back over the board, which slides in under it. */
const RIM = { cx: 670, cy: 370, rx: 312, ry: 291 };
const BASE = '/demo/';

type V3 = [number, number, number];
type P2 = [number, number];

function project(p: V3): P2 {
  const u = CX + (F * p[0]) / p[2];
  const v = CY + (F * p[1]) / p[2];
  const w = HC[2][0] * u + HC[2][1] * v + HC[2][2];
  return [(HC[0][0] * u + HC[0][1] * v + HC[0][2]) / w - CROP[0], (HC[1][0] * u + HC[1][1] * v + HC[1][2]) / w - CROP[1]];
}

const pts = (q: P2[]) => q.map((p) => p[0].toFixed(1) + ',' + p[1].toFixed(1)).join(' ');

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

/** The screen's glass (and the left side of its housing) turned toward the passenger by `a` radians. */
function screenGeometry(a: number) {
  const [X, Y, D] = SCREEN.c;
  const hw = SCREEN.w / 2;
  const hh = SCREEN.h / 2;
  const c = Math.cos(a);
  const s = Math.sin(a);
  const at = (x: number, y: number, back = 0): V3 => [X + x * c - back * s, Y + y, D + x * s + back * c];
  const glass = [at(-hw, -hh), at(hw, -hh), at(hw, hh), at(-hw, hh)].map(project);
  const side = [at(-hw, -hh), at(-hw, -hh, SCREEN.depth), at(-hw, hh, SCREEN.depth), at(-hw, hh)].map(project);
  return { glass, side };
}

function boardGeometry(dx: number) {
  const b = BOARD;
  const x0 = b.x0 + dx;
  const x1 = b.x1 + dx;
  const top = ([[x0, b.y, b.z1], [x1, b.y, b.z1], [x1, b.y, b.z0], [x0, b.y, b.z0]] as V3[]).map(project);
  const front = ([[x0, b.y, b.z0], [x1, b.y, b.z0], [x1, b.y + b.t, b.z0], [x0, b.y + b.t, b.z0]] as V3[]).map(project);
  return { top, front };
}

function macGeometry(dy: number) {
  const m = MAC;
  const y0 = BOARD.y + dy;
  const top = y0 - m.base;
  const up: V3 = [0, -Math.cos(m.lean), Math.sin(m.lean)];
  const lid = (x: number, t: number): V3 => [x, top + up[1] * t, m.zh + up[2] * t];
  const inset = 0.006;
  return {
    shadow: ([[m.x0 - 0.01, BOARD.y, m.zh + 0.01], [m.x1 + 0.02, BOARD.y, m.zh + 0.01], [m.x1 + 0.02, BOARD.y, m.zf - 0.015], [m.x0 - 0.01, BOARD.y, m.zf - 0.015]] as V3[]).map(project),
    deck: ([[m.x0, top, m.zh], [m.x1, top, m.zh], [m.x1, top, m.zf], [m.x0, top, m.zf]] as V3[]).map(project),
    front: ([[m.x0, top, m.zf], [m.x1, top, m.zf], [m.x1, y0, m.zf], [m.x0, y0, m.zf]] as V3[]).map(project),
    left: ([[m.x0, top, m.zh], [m.x0, top, m.zf], [m.x0, y0, m.zf], [m.x0, y0, m.zh]] as V3[]).map(project),
    lid: [lid(m.x0, m.lid), lid(m.x1, m.lid), lid(m.x1, 0), lid(m.x0, 0)].map(project),
    keys: ([[m.x0 + 0.018, top, m.zh - 0.012], [m.x1 - 0.018, top, m.zh - 0.012], [m.x1 - 0.018, top, m.zh - 0.118], [m.x0 + 0.018, top, m.zh - 0.118]] as V3[]).map(project),
    pad: ([[m.x0 + 0.095, top, m.zh - 0.13], [m.x1 - 0.095, top, m.zh - 0.13], [m.x1 - 0.095, top, m.zf + 0.012], [m.x0 + 0.095, top, m.zf + 0.012]] as V3[]).map(project),
    display: [lid(m.x0 + inset, m.lid - inset), lid(m.x1 - inset, m.lid - inset), lid(m.x1 - inset, 0.013), lid(m.x0 + inset, 0.013)].map(project),
  };
}

interface Pose {
  turn: number;
  board: number;
  mac: number;
  mirror: number;
}

/** Where each step leaves the scene. */
const POSES: Pose[] = [
  { turn: 1, board: 0, mac: 0, mirror: 0 },
  { turn: 1, board: 1, mac: 0, mirror: 0 },
  { turn: 1, board: 1, mac: 1, mirror: 1 },
];

/** How long each step stays up before the next, while nobody has picked one. */
const STEP_MS = 2800;

/**
 * "Your office, anywhere" as one dark passage in /powerwall's layout: the heading, then the composite across the
 * content column (a real Model 3 cabin by Bram Van Oost on Unsplash, with the setup drawn into it in the photo's
 * own perspective: the screen swivels toward the passenger, the trunk's subfloor cover slides in under the wheel,
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
  const pose = useRef<Pose>({ ...(reduced ? POSES[2] : { turn: 0, board: 0, mac: 0, mirror: 0 }) });
  const shown = useRef(reduced ? STEPS.length - 1 : -1);

  /** Draws the current pose: every part is recomputed from the model, so it stays in perspective. */
  const draw = useCallback(() => {
    const w = world.current;
    if (!w) return;
    const p = pose.current;
    const q = (s: string) => w.querySelector(s) as HTMLElement & SVGElement;
    const sc = screenGeometry(TURN * p.turn);
    q('.o-screen').style.transform = quadMatrix(TEX[0], TEX[1], sc.glass);
    q('.o-screen-mac').style.opacity = String(p.mirror);
    q('.o-side').setAttribute('points', pts(sc.side));
    q('.o-side').style.opacity = String(Math.min(1, p.turn * 1.5));
    const b = boardGeometry((1 - p.board) * 0.7);
    q('.o-board-top').setAttribute('points', pts(b.top));
    q('.o-board-front').setAttribute('points', pts(b.front));
    q('.o-board').style.opacity = String(Math.min(1, p.board * 2.5));
    const m = macGeometry(-(1 - p.mac) * 0.05);
    for (const k of ['shadow', 'deck', 'keys', 'pad', 'front', 'left', 'lid'] as const) q('.o-mac-' + k).setAttribute('points', pts(m[k]));
    q('.o-mac').style.opacity = String(p.mac);
    const disp = q('.o-mac-display');
    disp.style.transform = quadMatrix(1100, 714, m.display);
    disp.style.opacity = String(p.mac);
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
        // The swivel itself: back to straight ahead if needed, then round to the passenger.
        t.to(p, { board: 0, mac: 0, mirror: 0, duration: 0.3, ease: ease.tds }, 0);
        if (p.turn > 0) t.to(p, { turn: 0, duration: 0.25, ease: ease.tds }, 0);
        t.to(p, { turn: 1, duration: p.turn > 0 ? 0.5 : 0.7, ease: ease.tds }, p.turn > 0 ? 0.25 : 0);
      } else {
        t.to(p, { turn: 1, mac: to.mac === 0 ? 0 : p.mac, mirror: to.mirror === 0 ? 0 : p.mirror, duration: 0.3, ease: ease.tds }, 0);
        if (k === 1) t.to(p, { board: 1, duration: 0.7, ease: ease.mktg }, 0);
        else {
          t.to(p, { board: 1, duration: 0.4, ease: ease.mktg }, 0);
          t.to(p, { mac: 1, duration: 0.6, ease: ease.mktg }, 0.05);
          t.to(p, { mirror: 1, duration: 0.5, ease: ease.tds }, 0.2);
        }
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
    world.current?.querySelector('.o-rim')?.setAttribute('href', img.currentSrc || img.src);
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
              src={BASE + 'office-1400.webp'}
              srcSet={`${BASE}office-1400.webp 1400w, ${BASE}office-2000.webp 2000w, ${BASE}office-2700.webp 2700w`}
              sizes="(max-width: 1247px) 100vw, 1200px"
              alt=""
              decoding="async"
              onLoad={onPhoto}
            />
            <div className="o-world" ref={world} aria-hidden="true">
              <svg className="o-under" viewBox={`0 0 ${W} ${H}`} width={W} height={H}>
                <polygon className="o-side" />
              </svg>
              <div className="o-screen">
                <i className="o-screen-ui" />
                <i className="o-screen-mac" />
              </div>
              <svg className="o-over" viewBox={`0 0 ${W} ${H}`} width={W} height={H}>
                <defs>
                  <clipPath id="office-rim">
                    <ellipse cx={RIM.cx} cy={RIM.cy} rx={RIM.rx} ry={RIM.ry} />
                  </clipPath>
                  <linearGradient id="office-board" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0" stopColor="#3a3b3f" />
                    <stop offset="1" stopColor="#232427" />
                  </linearGradient>
                  <linearGradient id="office-deck" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0" stopColor="#6a6c71" />
                    <stop offset="1" stopColor="#4a4c50" />
                  </linearGradient>
                </defs>
                <g className="o-board">
                  <polygon className="o-board-top" fill="url(#office-board)" />
                  <polygon className="o-board-front" />
                </g>
                <image className="o-rim" href={BASE + 'office-1400.webp'} x="0" y="0" width={W} height={H} clipPath="url(#office-rim)" preserveAspectRatio="none" />
                <g className="o-mac">
                  <polygon className="o-mac-shadow" />
                  <polygon className="o-mac-left" />
                  <polygon className="o-mac-deck" fill="url(#office-deck)" />
                  <polygon className="o-mac-keys" />
                  <polygon className="o-mac-pad" />
                  <polygon className="o-mac-front" />
                  <polygon className="o-mac-lid" />
                </g>
              </svg>
              <div className="o-mac-display" />
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

        <p className="office__note">Our setup, in a Model 3/Y. Parked only. Take the board out before you drive.</p>
      </div>

      <Band />
    </section>
  );
}
