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
 * research/office/prep_office.py (grade, screen fit) and render_office.py (the board and the MacBook,
 * rendered in Blender through the photo's own fitted camera, then graded and grained into it) and render_office.py
 * (the whole scene: the board, the MacBook and the screen's swivel as a real slab in front of the projected photo).
 */
const W = 2700;
const H = 1460;
/** The swivel's window in the crop (x, y, w, h): the clip, its last frame and the desk still, from prep_office.py. */
const SWIVEL = [1008, 132, 664, 488];
/** The turn's clip length (s): 27 frames at 30 fps, from 0° to 30° toward the passenger. */
const TURN_S = 0.9;
/** The rendered sprites' places in the crop (x, y, w, h), from prep_office.py. */
const BOARD_SPRITE = [308, 633, 1870, 362];
const MAC_SPRITE = [1356, 398, 801, 456];
/** The steering wheel in the photo (crop px): its rim and lower spoke are drawn back over the board. */
const RIM = { cx: 670, cy: 370, rx: 312, ry: 291 };
const RIM_T = 45;
const ellipsePath = (cx: number, cy: number, rx: number, ry: number) => `M${cx - rx} ${cy} a${rx} ${ry} 0 1 0 ${2 * rx} 0 a${rx} ${ry} 0 1 0 ${-2 * rx} 0 Z`;
const RIM_RING = ellipsePath(RIM.cx, RIM.cy, RIM.rx, RIM.ry) + ' ' + ellipsePath(RIM.cx, RIM.cy, RIM.rx - RIM_T, RIM.ry - RIM_T);
const BASE = '/demo/';

interface Pose {
  /** The turned screen at rest (the clip's last frame). */
  turned: number;
  /** The clip of the turn itself, while it plays. */
  clip: number;
  board: number;
  mac: number;
  mirror: number;
}

/** Where each step leaves the scene. */
const POSES: Pose[] = [
  { turned: 1, clip: 0, board: 0, mac: 0, mirror: 0 },
  { turned: 1, clip: 0, board: 1, mac: 0, mirror: 0 },
  { turned: 1, clip: 0, board: 1, mac: 1, mirror: 1 },
];
const OPENING: Pose = { turned: 0, clip: 0, board: 0, mac: 0, mirror: 0 };

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
  const pose = useRef<Pose>({ ...(reduced ? POSES[2] : OPENING) });
  const shown = useRef(reduced ? STEPS.length - 1 : -1);

  /** Draws the current pose. The board slides in from the passenger side, under the rim. */
  const draw = useCallback(() => {
    const w = world.current;
    if (!w) return;
    const p = pose.current;
    const q = (s: string) => w.querySelector(s) as HTMLElement;
    const clip = w.querySelector<HTMLElement>('.o-swivel-clip');
    if (clip) clip.style.opacity = String(p.clip);
    q('.o-swivel-end').style.opacity = String(p.turned);
    q('.o-swivel-desk').style.opacity = String(p.mirror * p.turned);
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
      const clip = world.current?.querySelector('.o-swivel-clip') as HTMLVideoElement | null;
      if (k === 0) {
        // Back to the photo as it is (if anything was set up), then the screen turns: the clip plays once and
        // hands over to its last frame; if it can't play, the last frame fades in over the same time.
        const busy = p.turned + p.board + p.mac > 0;
        t.to(p, { turned: 0, clip: 0, board: 0, mac: 0, mirror: 0, duration: busy ? 0.4 : 0, ease: ease.tds }, 0);
        t.call(() => {
          const fallback = () => {
            if (p.turned === 0 && p.clip === 0) gsap.to(p, { turned: 1, duration: TURN_S, ease: ease.tds, onUpdate: draw });
          };
          if (!clip) return fallback();
          clip.currentTime = 0;
          // Shown from its first painted frame (≈ the photo), so nothing flashes while it loads.
          clip.addEventListener(
            'playing',
            () => {
              p.clip = 1;
              draw();
            },
            { once: true },
          );
          const played = clip.play();
          if (played) played.catch(fallback);
          window.setTimeout(fallback, 2500);
        });
      } else {
        if (p.turned < 1 && !(clip && !clip.paused)) t.to(p, { turned: 1, duration: 0.4, ease: ease.tds }, 0);
        if (k === 1) {
          t.to(p, { mac: 0, mirror: 0, duration: 0.3, ease: ease.tds }, 0);
          t.to(p, { board: 1, duration: 0.7, ease: ease.mktg }, 0);
        } else {
          t.to(p, { board: 1, duration: 0.4, ease: ease.mktg }, 0);
          t.to(p, { mac: 1, duration: 0.6, ease: ease.mktg }, 0.05);
          t.to(p, { mirror: 1, duration: 0.55, ease: ease.tds }, 0.15);
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

  // The clip loads once the section is near; when it ends, its last frame (the still) takes over.
  useEffect(() => {
    const clip = world.current?.querySelector('.o-swivel-clip') as HTMLVideoElement | null;
    if (!clip || reduced) return;
    const ended = () => {
      pose.current.turned = 1;
      pose.current.clip = 0;
      draw();
    };
    clip.addEventListener('ended', ended);
    return () => clip.removeEventListener('ended', ended);
  }, [draw, reduced]);

  useEffect(() => {
    const clip = world.current?.querySelector('.o-swivel-clip') as HTMLVideoElement | null;
    if (inView && clip && clip.preload === 'none') {
      clip.preload = 'auto';
      clip.load();
    }
  }, [inView]);

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
              <div className="o-swivel" style={{ transform: `translate(${SWIVEL[0]}px, ${SWIVEL[1]}px)`, width: SWIVEL[2], height: SWIVEL[3] }}>
                <img className="o-swivel-end" src={BASE + 'office-swivel-end.webp' + ASSET_V} alt="" loading="lazy" decoding="async" />
                <img className="o-swivel-desk" src={BASE + 'office-swivel-desk.webp' + ASSET_V} alt="" loading="lazy" decoding="async" />
                {!reduced && (
                  <video className="o-swivel-clip" muted playsInline preload="none" disablePictureInPicture>
                    <source src={BASE + 'office-swivel.webm' + ASSET_V} type="video/webm" />
                    <source src={BASE + 'office-swivel.mp4' + ASSET_V} type="video/mp4" />
                  </video>
                )}
              </div>
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
