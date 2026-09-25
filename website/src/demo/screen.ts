import gsap from 'gsap';
import { createCarClient, type CarClient } from './client/client';
import { encodeSize, statsRows, TIERS, type Playout, type TierId } from './client/stats';
import { createDesktop, type Desktop, type DisplayMode } from './mac/desktop';
import { createTesla, type TeslaUI } from './tesla/tesla';
import { Finger } from './fingers';
import { ASSETS } from './assets';
import './screen.css';

/** The car browser's device-pixel ratio (Chromium 148, 2026.26): 1920 px panel = 1255 CSS px. */
export const DPR = 1.53;

/** Story length; the loop restarts from the windowed browser. */
const LOOP = 30;
/** Time the visitor's first touch jumps to: desktop streaming, veil gone. */
const LIVE = 7.9;

export type Story = 'full' | 'loop' | 'film';

export interface ScreenOptions {
  display: DisplayMode;
  tier: TierId;
  stats: boolean;
  /**
   * 'full': the 30 s connect story. 'loop': the payoff only, a calm 10 s loop of the streaming desktop.
   * 'film': a still desktop with the film large and playing, nothing else moving.
   */
  story?: Story;
  onCue?: (cue: Cue) => void;
}

export type Cue = 'connect' | 'theater' | 'tap' | 'desktop' | 'drag' | 'scroll' | 'sound';

interface State {
  full: number;
  stream: number;
  cx: number;
  cy: number;
  cursor: number;
  sx: number;
  sy: number;
  px: number;
  py: number;
  scroll: number;
}

const SCROLL_MAX = 900;

const reducedMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/**
 * One car screen at native 1920×1200: the Tesla UI with the browser, the real Dashcast client in the
 * browser's page area, and the streamed Mac desktop inside the client. A GSAP timeline plays the
 * story; the touch methods hand the screen to a visitor instead.
 */
export class DemoScreen {
  readonly el: HTMLDivElement;
  readonly tesla: TeslaUI;
  readonly client: CarClient;
  readonly desk: Desktop;
  private f1: Finger;
  private f2: Finger;
  private s: State;
  private opts: ScreenOptions;
  private tl: gsap.core.Timeline | null = null;
  private raf = 0;
  private frame = -1;
  private tick = 0;
  private statsTimer = 0;
  private tapped = false;
  private streaming = false;
  private playout: Playout = 'interactive';
  private audio = false;
  private manual = false;
  private running = false;
  private cue: Cue = 'connect';
  private clientSize = [0, 0];
  private toast: HTMLDivElement;
  private story: Story = 'full';

  constructor(opts: ScreenOptions) {
    this.opts = { ...opts };
    this.tesla = createTesla();
    this.el = this.tesla.root;
    this.client = createCarClient();
    this.desk = createDesktop({ wallpaper: ASSETS.wallpaper, clip: ASSETS.clip });
    this.client.stream.appendChild(this.desk.root);
    this.tesla.viewport.appendChild(this.client.root);
    this.toast = document.createElement('div');
    this.toast.className = 'dm-dcc-toast';
    this.toast.hidden = true;
    this.toast.innerHTML =
      "<b>Fullscreen isn't available here</b><span>This browser blocks the Fullscreen API. In a Tesla, pages opened through youtube.com/redirect load in Theater mode.</span><br><a>Open in Theater mode</a>";
    this.client.root.appendChild(this.toast);
    const fingers = document.createElement('div');
    fingers.className = 'dm-fg-layer';
    this.el.appendChild(fingers);
    this.f1 = new Finger(fingers);
    this.f2 = new Finger(fingers);
    this.desk.setMode(opts.display);
    this.s = this.initial();
    this.el.dataset.tier = opts.tier;
    this.tesla.setSecure(TIERS[opts.tier].transport === 'ws');
    this.client.showStats(opts.stats);
    this.desk.video.addEventListener('timeupdate', () => this.hud());
    this.reset();
    this.render(true);
    if (opts.story === 'loop') {
      this.story = 'loop';
      this.settle(true);
      Object.assign(this.s, this.loopStart());
      this.render(true);
    }
    if (opts.story === 'film') this.filmScene();
  }

  private initial(): State {
    const L = this.desk.layout;
    return { full: 0, stream: 0, cx: L.w / 2, cy: L.h / 2, cursor: 0, sx: L.safari.x, sy: L.safari.y, px: L.player.x, py: L.player.y, scroll: 0 };
  }

  // ---- options ---------------------------------------------------------------------

  setDisplay(d: DisplayMode) {
    if (d === this.opts.display) return;
    this.opts.display = d;
    const t = this.tl ? this.tl.time() : 0;
    this.desk.setMode(d);
    const L = this.desk.layout;
    Object.assign(this.s, { sx: L.safari.x, sy: L.safari.y, px: L.player.x, py: L.player.y, scroll: Math.min(this.s.scroll, SCROLL_MAX) });
    if (this.tl && !this.manual) {
      if (this.story === 'loop') this.buildLoop();
      else this.build();
      this.tl!.time(t, true);
      if (this.running) this.tl.play();
    }
    this.fit(true);
    this.render(true);
  }

  setTier(t: TierId) {
    this.opts.tier = t;
    this.el.dataset.tier = t;
    this.tesla.setSecure(TIERS[t].transport === 'ws');
    this.frame = -1;
    this.renderStats();
  }

  setStats(on: boolean) {
    this.opts.stats = on;
    this.client.showStats(on);
    this.renderStats();
  }

  // ---- story -----------------------------------------------------------------------

  /** The loop's first frame: windowed browser, the Dashcast page connecting behind its veil. */
  private reset() {
    this.tapped = false;
    this.streaming = false;
    this.audio = false;
    this.manual = false;
    this.playout = 'interactive';
    this.client.paintMode('auto');
    this.client.status('Connecting…');
    this.client.resetTap();
    this.client.kbBtn.hidden = true;
    this.client.fsBtn.classList.remove('dm-on');
    this.toast.hidden = true;
    this.tesla.setHint(false);
    this.desk.resetFilm();
    this.desk.player.classList.remove('dm-playing', 'dm-calm');
    this.desk.front(this.desk.safari);
    Object.assign(this.s, this.initial());
    this.f1.on = this.f2.on = this.f1.press = this.f2.press = 0;
    this.setCue('connect');
    this.renderStats();
  }

  private build() {
    if (this.tl) this.tl.kill();
    const s = this.s;
    const f1 = this.f1;
    const f2 = this.f2;
    const L = this.desk.layout;
    const tl = gsap.timeline({ paused: true, repeat: -1, onUpdate: () => this.render(false), onRepeat: () => this.reset() });
    const at = (t: number, fn: () => void) => tl.call(fn, undefined, t);
    const dp = (x: number, y: number) => this.deskToPanel(x, y);
    /** A fingertip lands at `where` (panel px) at time t and lifts after `hold`. */
    const touch = (f: Finger, t: number, where: () => [number, number], hold = 0.16) => {
      at(t - 0.32, () => {
        const [x, y] = where();
        f.x = x;
        f.y = y;
      });
      tl.to(f, { on: 1, duration: 0.28, ease: 'power2.out' }, t - 0.32);
      tl.to(f, { press: 1, duration: 0.08, ease: 'power1.in' }, t - 0.06);
      tl.fromTo(f, { ring: 0 }, { ring: 1, duration: 0.7, ease: 'power3.out', immediateRender: false }, t);
      tl.to(f, { press: 0, duration: 0.14, ease: 'power1.out' }, t + hold - 0.04);
      tl.to(f, { on: 0, duration: 0.35, ease: 'power2.in' }, t + hold + 0.08);
    };

    // 1 · Windowed browser: the Dashcast page finds the Mac.
    at(1.2, () => this.client.status('Waiting for Mac', 'dm-wait'));
    // 2 · Its fullscreen button → the client's Theater hint → youtube.com/redirect → Theater.
    touch(f1, 2.4, () => this.clientButton(this.client.fsBtn));
    at(2.4, () => this.client.fsBtn.classList.add('dm-on'));
    at(2.55, () => {
      this.client.fsBtn.classList.remove('dm-on');
      this.toast.hidden = false;
    });
    touch(f1, 3.7, () => this.toastLink());
    at(3.85, () => {
      this.toast.hidden = true;
      this.setCue('theater');
    });
    tl.to(s, { full: 1, duration: 1.05, ease: 'none' }, 3.95);
    at(4.5, () => {
      this.tesla.setHint(true);
      this.client.status('Connecting…');
    });
    at(5.5, () => this.client.status('Waiting for Mac', 'dm-wait'));
    at(6.3, () => this.tesla.setHint(false));
    // 3 · The Mac's first frame arrives behind the Tap-to-start veil.
    at(6.5, () => {
      this.streaming = true;
      this.client.status(null);
      this.client.kbBtn.hidden = false;
      this.renderStats();
    });
    tl.to(s, { stream: 1, duration: 0.6, ease: 'power1.out' }, 6.5);
    // 4 · Tap to start (turns on sound and touch). The tap is also a click: the pointer jumps there.
    at(6.9, () => this.setCue('tap'));
    touch(f1, 7.5, () => this.playButton(), 0.18);
    at(7.5, () => this.client.tap.classList.add('dm-press'));
    at(7.7, () => {
      this.desk.video.preload = 'auto';
      this.tapped = true;
      this.client.dismissTap();
      this.renderStats();
      this.setCue('desktop');
      const [x, y] = this.panelToDesk(...this.playButton());
      s.cx = x;
      s.cy = y;
    });
    tl.to(s, { cursor: 1, duration: 0.2 }, 7.7);

    // 5 · Drag Safari by its toolbar.
    const gx = L.safari.x + L.safari.w * 0.62;
    const gy = L.safari.y + 26;
    const [dx, dy] = this.dragBy();
    at(8.8, () => this.setCue('drag'));
    at(9.0, () => {
      [f1.x, f1.y] = dp(gx, gy);
    });
    tl.to(f1, { on: 1, duration: 0.28, ease: 'power2.out' }, 9.0);
    tl.to(s, { cx: gx, cy: gy, duration: 0.01 }, 9.26);
    tl.to(f1, { press: 1, duration: 0.1 }, 9.22);
    tl.fromTo(f1, { ring: 0 }, { ring: 1, duration: 0.7, ease: 'power3.out', immediateRender: false }, 9.3);
    at(9.3, () => this.desk.front(this.desk.safari));
    tl.to(s, { sx: L.safari.x + dx, sy: L.safari.y + dy, cx: gx + dx, cy: gy + dy, duration: 1.5, ease: 'power2.inOut' }, 9.5);
    tl.to(f1, { x: () => dp(gx + dx, gy + dy)[0], y: () => dp(gx + dx, gy + dy)[1], duration: 1.5, ease: 'power2.inOut' }, 9.5);
    tl.to(f1, { press: 0, duration: 0.12 }, 11.05);
    tl.to(f1, { on: 0, duration: 0.35, ease: 'power2.in' }, 11.15);

    // 6 · Two-finger scroll on the article: fingers up, page down (natural scrolling).
    const sx = L.safari.x + dx + L.safari.w * 0.46;
    const sy = L.safari.y + dy + L.safari.h * 0.74;
    at(11.8, () => {
      this.setCue('scroll');
      [f1.x, f1.y] = dp(sx - 36, sy);
      [f2.x, f2.y] = dp(sx + 36, sy + 8);
    });
    tl.to([f1, f2], { on: 1, duration: 0.28, ease: 'power2.out' }, 11.85);
    tl.to([f1, f2], { press: 1, duration: 0.1 }, 12.15);
    tl.to(f1, { y: () => dp(sx, sy - 250)[1], duration: 1.05, ease: 'power2.inOut' }, 12.25);
    tl.to(f2, { y: () => dp(sx, sy - 242)[1], duration: 1.05, ease: 'power2.inOut' }, 12.25);
    tl.to(s, { scroll: 470, duration: 2.1, ease: 'expo.out' }, 12.35);
    tl.to([f1, f2], { press: 0, duration: 0.1 }, 13.3);
    tl.to([f1, f2], { on: 0, duration: 0.35, ease: 'power2.in' }, 13.35);

    // 7 · Play the film; with sound on and nobody touching, Auto switches to Cinema.
    const px = L.player.x + L.player.w / 2 - 180 + 16 + 8;
    const py = L.player.y + L.player.h - 16 - 20;
    touch(f1, 14.6, () => dp(px, py));
    tl.to(s, { cx: px, cy: py, duration: 0.01 }, 14.6);
    at(14.6, () => {
      this.desk.front(this.desk.player);
      this.desk.player.classList.remove('dm-calm');
    });
    at(14.75, () => this.playVideo());
    at(15.9, () => {
      this.audio = true;
      this.playout = 'cinema';
      this.renderStats();
      this.setCue('sound');
    });
    at(16.9, () => this.desk.player.classList.add('dm-calm'));
    tl.to(s, { cursor: 0, duration: 0.6 }, 17.4);

    // 8 · Calm out: the stream ends, Theater is swiped away, the page is back where it started.
    at(26.6, () => this.setCue('connect'));
    tl.to(s, { stream: 0, duration: 0.8, ease: 'power1.inOut' }, 26.6);
    at(27.4, () => {
      this.desk.video.pause();
      this.streaming = false;
      this.tapped = false;
      this.audio = false;
      this.playout = 'interactive';
      this.client.status('Connecting…');
      this.client.resetTap();
      this.client.kbBtn.hidden = true;
      this.renderStats();
    });
    tl.to(s, { full: 0, duration: 1.2, ease: 'none' }, 27.6);
    tl.set({}, {}, LOOP);
    this.tl = tl;
  }

  /** Theater, the film in a large window, Safari put away; plays on the display's own frame clock. */
  private filmScene() {
    this.story = 'film';
    this.settle(true);
    const L = this.desk.layout;
    const w = Math.round(L.w * 0.8);
    const h = Math.round((w * 9) / 16);
    this.desk.sizePlayer(w, h);
    this.desk.safari.style.visibility = 'hidden';
    this.desk.setApp('QuickTime Player');
    Object.assign(this.s, { px: Math.round((L.w - w) / 2), py: Math.round(L.menu + (L.h - L.menu - h) / 2), cursor: 0 });
    this.manual = true;
    this.render(true);
  }

  /** The loop's first (and last) frame: Safari home, page at the top, pointer on its toolbar. */
  private loopStart() {
    const L = this.desk.layout;
    return { sx: L.safari.x, sy: L.safari.y, scroll: 0, cursor: 1, cx: L.safari.x + L.safari.w * 0.62, cy: L.safari.y + 26 };
  }

  /** How far the story drags Safari. */
  private dragBy(): [number, number] {
    const L = this.desk.layout;
    return [Math.round(L.w * 0.08), Math.round(L.h * 0.05)];
  }

  /**
   * The capture loop (10 s, the film's own loop length): the settled desktop with the film playing;
   * Safari is dragged out and back and its page scrolled down and back up, so the last frame is the first.
   */
  private buildLoop() {
    if (this.tl) this.tl.kill();
    const s = this.s;
    const f1 = this.f1;
    const f2 = this.f2;
    const L = this.desk.layout;
    const dp = (x: number, y: number) => this.deskToPanel(x, y);
    const [dx, dy] = this.dragBy();
    const tl = gsap.timeline({ paused: true, repeat: -1, onUpdate: () => this.render(false) });
    const gx = L.safari.x + L.safari.w * 0.62;
    const gy = L.safari.y + 26;
    const drag = (t: number, from: [number, number], to: [number, number]) => {
      tl.set(f1, { x: () => dp(gx + from[0], gy + from[1])[0], y: () => dp(gx + from[0], gy + from[1])[1] }, t);
      tl.to(f1, { on: 1, duration: 0.28, ease: 'power2.out' }, t);
      tl.to(f1, { press: 1, duration: 0.1 }, t + 0.24);
      tl.fromTo(f1, { ring: 0 }, { ring: 1, duration: 0.7, ease: 'power3.out', immediateRender: false }, t + 0.3);
      tl.to(s, { cx: gx + from[0], cy: gy + from[1], duration: 0.01 }, t + 0.26);
      tl.to(s, { sx: L.safari.x + to[0], sy: L.safari.y + to[1], cx: gx + to[0], cy: gy + to[1], duration: 1.5, ease: 'power2.inOut' }, t + 0.5);
      tl.to(f1, { x: () => dp(gx + to[0], gy + to[1])[0], y: () => dp(gx + to[0], gy + to[1])[1], duration: 1.5, ease: 'power2.inOut' }, t + 0.5);
      tl.to(f1, { press: 0, duration: 0.12 }, t + 2.05);
      tl.to(f1, { on: 0, duration: 0.35, ease: 'power2.in' }, t + 2.15);
    };
    const scroll = (t: number, to: number, up: boolean) => {
      const x = L.safari.x + dx + L.safari.w * 0.46;
      const y = L.safari.y + dy + L.safari.h * (up ? 0.74 : 0.4);
      const d = up ? -250 : 250;
      tl.set(f1, { x: () => dp(x - 36, y)[0], y: () => dp(x - 36, y)[1] }, t);
      tl.set(f2, { x: () => dp(x + 36, y + 8)[0], y: () => dp(x + 36, y + 8)[1] }, t);
      tl.to([f1, f2], { on: 1, duration: 0.28, ease: 'power2.out' }, t);
      tl.to([f1, f2], { press: 1, duration: 0.1 }, t + 0.3);
      tl.to(f1, { y: () => dp(x, y + d)[1], duration: 1.05, ease: 'power2.inOut' }, t + 0.4);
      tl.to(f2, { y: () => dp(x, y + d + 8)[1], duration: 1.05, ease: 'power2.inOut' }, t + 0.4);
      tl.to(s, { scroll: to, duration: 1.6, ease: 'power3.out' }, t + 0.5);
      tl.to([f1, f2], { press: 0, duration: 0.1 }, t + 1.45);
      tl.to([f1, f2], { on: 0, duration: 0.35, ease: 'power2.in' }, t + 1.5);
    };
    tl.set(s, this.loopStart(), 0);
    drag(0.2, [0, 0], [dx, dy]);
    scroll(2.9, 380, true);
    scroll(5.0, 0, false);
    drag(7.1, [dx, dy], [0, 0]);
    tl.set({}, {}, 10);
    this.tl = tl;
  }

  // ---- geometry --------------------------------------------------------------------

  private deskFit() {
    const L = this.desk.layout;
    const [cw, ch] = this.clientSize;
    const k = Math.min(cw / L.w, ch / L.h);
    return { k, ox: (cw - L.w * k) / 2, oy: (ch - L.h * k) / 2 };
  }

  private viewportToPanel(x: number, y: number): [number, number] {
    const r = this.tesla.viewportRect(this.s.full);
    return [r.x + (x * r.w) / this.clientSize[0], r.y + (y * r.h) / this.clientSize[1]];
  }

  private deskToPanel(x: number, y: number): [number, number] {
    const { k, ox, oy } = this.deskFit();
    return this.viewportToPanel(ox + x * k, oy + y * k);
  }

  private panelToDesk(x: number, y: number): [number, number] {
    const r = this.tesla.viewportRect(this.s.full);
    const { k, ox, oy } = this.deskFit();
    const cx = ((x - r.x) * this.clientSize[0]) / r.w;
    const cy = ((y - r.y) * this.clientSize[1]) / r.h;
    return [(cx - ox) / k, (cy - oy) / k];
  }

  /** Panel px of the centre of one of the client's corner buttons. */
  private clientButton(b: HTMLElement): [number, number] {
    const bar = this.client.bar;
    return this.viewportToPanel(bar.offsetLeft + b.offsetLeft + b.offsetWidth / 2, bar.offsetTop + b.offsetTop + b.offsetHeight / 2);
  }

  private toastLink(): [number, number] {
    const t = this.toast;
    const wasHidden = t.hidden;
    t.hidden = false;
    const a = t.querySelector('a') as HTMLElement;
    const x = t.offsetLeft - t.offsetWidth / 2 + a.offsetLeft + a.offsetWidth / 2;
    const y = t.offsetTop + a.offsetTop + a.offsetHeight / 2;
    t.hidden = wasHidden;
    return this.viewportToPanel(x, y);
  }

  private playButton(): [number, number] {
    const p = this.client.tap.querySelector('.dm-dcc-play') as HTMLElement;
    return this.viewportToPanel(p.offsetLeft + p.offsetWidth / 2, p.offsetTop + p.offsetHeight / 2);
  }

  /** Lays the client out in the browser's page area (CSS px = panel px / DPR) and letterboxes the desktop. */
  private fit(force: boolean) {
    const r = this.tesla.viewportRect(this.s.full);
    const cw = Math.round(r.w / DPR);
    const ch = Math.round(r.h / DPR);
    if (!force && cw === this.clientSize[0] && ch === this.clientSize[1]) return;
    this.clientSize = [cw, ch];
    const c = this.client.root;
    c.style.width = cw + 'px';
    c.style.height = ch + 'px';
    c.style.transform = `scale(${r.w / cw}, ${r.h / ch})`;
    const { k, ox, oy } = this.deskFit();
    this.desk.root.style.transform = `translate(${ox}px, ${oy}px) scale(${k})`;
    this.renderStats();
  }

  // ---- rendering -------------------------------------------------------------------

  private render(force: boolean) {
    const s = this.s;
    this.tesla.setFull(s.full);
    this.fit(force);
    this.f1.apply();
    this.f2.apply();
    this.desk.root.style.opacity = String(s.stream);
    // The streamed picture only changes on the tier's frame clock (30 or 60 fps).
    const fps = TIERS[this.opts.tier].fps;
    const now = this.tl && !this.manual ? this.tl.time() : performance.now() / 1000;
    const frame = Math.floor(now * fps);
    // 30 fps is quantised; 60 fps just follows the display (a 60 Hz car panel), which avoids
    // doubled frames when rAF jitters across a 1/60 s boundary.
    if (!force && fps < 60 && frame === this.frame) return;
    this.frame = frame;
    const d = this.desk;
    d.cursor.style.transform = `translate(${s.cx}px, ${s.cy}px)`;
    d.cursor.style.opacity = String(s.cursor);
    d.safari.style.transform = `translate(${s.sx}px, ${s.sy}px)`;
    d.player.style.transform = `translate(${s.px}px, ${s.py}px)`;
    d.page.style.transform = `translateY(${-s.scroll}px)`;
    if (!d.video.paused) d.drawFilm();
  }

  private loop = () => {
    this.raf = 0;
    if (!this.running || !this.manual) return;
    this.render(false);
    this.raf = requestAnimationFrame(this.loop);
  };

  private renderStats() {
    if (!this.opts.stats) return;
    const t = TIERS[this.opts.tier];
    const frame = encodeSize(t.budget, this.clientSize[0] || 1255, this.clientSize[1] || 745, DPR);
    this.client.renderStats(
      statsRows({ tier: this.opts.tier, frame, playout: this.playout, streaming: this.streaming, tapped: this.tapped, audioPlaying: this.audio, tick: this.tick }),
    );
  }

  private setCue(c: Cue) {
    if (c === this.cue) return;
    this.cue = c;
    if (this.opts.onCue) this.opts.onCue(c);
  }

  private hud() {
    const v = this.desk.video;
    const bar = this.desk.playerHud.querySelector('.dm-qt-track i') as HTMLElement;
    const t = this.desk.playerHud.querySelectorAll('.dm-qt-t');
    if (v.duration) bar.style.transform = `scaleX(${v.currentTime / v.duration})`;
    t[0].textContent = '0:' + String(Math.floor(v.currentTime)).padStart(2, '0');
  }

  private playVideo() {
    const v = this.desk.video;
    v.preload = 'auto';
    this.desk.player.classList.add('dm-playing');
    const p = v.play();
    if (p) p.catch(() => {});
  }

  // ---- playback --------------------------------------------------------------------

  play() {
    if (this.running) return;
    this.running = true;
    if (this.manual) this.raf = requestAnimationFrame(this.loop);
    else {
      if (!this.tl) {
        if (this.story === 'loop') this.buildLoop();
        else this.build();
      }
      this.tl!.play();
    }
    if (this.audio && this.desk.player.classList.contains('dm-playing')) this.desk.video.play().catch(() => {});
    this.statsTimer = window.setInterval(() => {
      this.tick++;
      this.renderStats();
      this.desk.clock(new Date());
    }, 1000);
  }

  pause() {
    if (!this.running) return;
    this.running = false;
    if (this.tl) this.tl.pause();
    cancelAnimationFrame(this.raf);
    this.raf = 0;
    clearInterval(this.statsTimer);
    this.desk.video.pause();
  }

  /** The settled frame: Theater, the desktop streaming, Safari moved and scrolled, the film on its poster. */
  private settle(filmPlaying: boolean) {
    const L = this.desk.layout;
    const [dx, dy] = this.dragBy();
    this.reset();
    Object.assign(this.s, { full: 1, stream: 1, cursor: filmPlaying ? 1 : 0, sx: L.safari.x + dx, sy: L.safari.y + dy, scroll: 470 });
    this.streaming = true;
    this.tapped = true;
    this.client.status(null);
    this.client.dismissTap();
    this.client.kbBtn.hidden = false;
    this.desk.front(this.desk.player);
    this.desk.player.classList.add('dm-calm');
    if (filmPlaying) {
      this.audio = true;
      this.playout = 'cinema';
      this.desk.player.classList.add('dm-playing');
      this.setCue('sound');
    } else this.setCue('desktop');
    this.fit(true);
    this.render(true);
    this.renderStats();
  }

  /** Reduced motion: a static, meaningful frame; no timeline, no timers. */
  still() {
    this.pause();
    if (this.story === 'film') {
      this.render(true);
      return;
    }
    if (this.tl) this.tl.kill();
    this.tl = null;
    this.settle(false);
  }

  /** Capture mode: the 10 s seamless loop, paused; `seek` renders any instant of it deterministically. */
  capture() {
    this.pause();
    this.settle(true);
    Object.assign(this.s, this.loopStart());
    this.story = 'loop';
    this.buildLoop();
    const v = this.desk.video;
    v.preload = 'auto';
    v.loop = true;
  }

  async seek(t: number) {
    const tt = ((t % 10) + 10) % 10;
    if (!this.tl) this.buildLoop();
    this.tl!.pause();
    this.tl!.time(tt, false);
    this.render(true);
    const v = this.desk.video;
    if (v.readyState < 1) await new Promise((r) => v.addEventListener('loadedmetadata', r, { once: true }));
    await new Promise<void>((r) => {
      const done = () => r();
      v.addEventListener('seeked', done, { once: true });
      v.currentTime = Math.min(tt, (v.duration || 10) - 0.001);
      setTimeout(done, 1500);
    });
    this.desk.drawFilm();
    this.hud();
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  }

  restart() {
    if (this.story === 'film') return;
    this.story = this.opts.story || 'full';
    if (this.tl) this.tl.kill();
    this.tl = null;
    cancelAnimationFrame(this.raf);
    this.raf = 0;
    if (this.story === 'loop') {
      this.settle(true);
      Object.assign(this.s, this.loopStart());
      this.buildLoop();
    } else {
      this.reset();
      this.build();
    }
    this.render(true);
    if (this.running) {
      this.tl!.play(0);
      if (this.audio) this.desk.video.play().catch(() => {});
    }
  }

  destroy() {
    this.pause();
    if (this.tl) this.tl.kill();
    gsap.killTweensOf([this.f1, this.f2]);
    this.desk.video.removeAttribute('src');
    this.desk.video.load();
    this.el.remove();
  }

  // ---- visitor touch (panel px) ------------------------------------------------------

  /** Stops the story where it is (skipping ahead to the live desktop) and hands the screen over. */
  private takeOver() {
    if (this.manual) return;
    if (this.tl) {
      if (this.story === 'full' && (this.tl.time() < LIVE || this.tl.time() > 26.5)) {
        this.reset();
        this.tl.time(LIVE, false);
      }
      this.tl.pause();
    }
    this.manual = true;
    Object.assign(this.s, { full: 1, stream: 1, cursor: 1 });
    this.streaming = true;
    this.tapped = true;
    this.toast.hidden = true;
    this.tesla.setHint(false);
    this.client.status(null);
    this.client.dismissTap();
    this.client.kbBtn.hidden = false;
    this.fit(true);
    this.renderStats();
    if (this.running && !this.raf) this.raf = requestAnimationFrame(this.loop);
  }

  private drag: { win: HTMLDivElement | null; ox: number; oy: number; mx: number; my: number; moved: boolean } | null = null;

  touchStart(px: number, py: number) {
    this.takeOver();
    const [x, y] = this.panelToDesk(px, py);
    const s = this.s;
    s.cx = x;
    s.cy = y;
    s.cursor = 1;
    gsap.killTweensOf(this.f1);
    this.f1.x = px;
    this.f1.y = py;
    this.f1.on = 1;
    this.f1.press = 1;
    if (!reducedMotion()) gsap.fromTo(this.f1, { ring: 0 }, { ring: 1, duration: 0.7, ease: 'power3.out', onUpdate: () => this.f1.apply() });
    const L = this.desk.layout;
    const inBox = (bx: number, by: number, w: number, h: number) => x >= bx && x <= bx + w && y >= by && y <= by + h;
    const hitS = inBox(s.sx, s.sy, L.safari.w, L.safari.h);
    const hitP = inBox(s.px, s.py, L.player.w, L.player.h);
    const safariOnTop = Number(this.desk.safari.style.zIndex) > Number(this.desk.player.style.zIndex);
    const win = hitS && hitP ? (safariOnTop ? this.desk.safari : this.desk.player) : hitS ? this.desk.safari : hitP ? this.desk.player : null;
    if (win) this.desk.front(win);
    if (win === this.desk.player) this.desk.player.classList.remove('dm-calm');
    this.drag = { win, ox: win === this.desk.safari ? s.sx : s.px, oy: win === this.desk.safari ? s.sy : s.py, mx: x, my: y, moved: false };
    if (this.playout === 'cinema') {
      this.playout = 'interactive';
      this.renderStats();
    }
    this.render(true);
  }

  touchMove(px: number, py: number) {
    const d = this.drag;
    if (!d) return;
    const [x, y] = this.panelToDesk(px, py);
    const s = this.s;
    const L = this.desk.layout;
    s.cx = x;
    s.cy = y;
    this.f1.x = px;
    this.f1.y = py;
    if (Math.hypot(x - d.mx, y - d.my) > 6) d.moved = true;
    if (d.win && d.moved) {
      const nx = d.ox + x - d.mx;
      const ny = Math.max(L.menu, d.oy + y - d.my);
      if (d.win === this.desk.safari) {
        s.sx = nx;
        s.sy = ny;
      } else {
        s.px = nx;
        s.py = ny;
      }
    }
    if (!this.running) this.render(true);
  }

  touchEnd() {
    const d = this.drag;
    this.drag = null;
    if (reducedMotion()) {
      this.f1.on = this.f1.press = 0;
      this.f1.apply();
    } else gsap.to(this.f1, { on: 0, press: 0, duration: 0.35, ease: 'power2.in', onUpdate: () => this.f1.apply() });
    if (!d || d.moved || d.win !== this.desk.player) return;
    const v = this.desk.video;
    if (v.paused) {
      this.playVideo();
      this.audio = true;
      window.setTimeout(() => {
        if (v.paused || this.drag) return;
        this.playout = 'cinema';
        this.renderStats();
        this.setCue('sound');
        this.desk.player.classList.add('dm-calm');
      }, 1200);
    } else {
      v.pause();
      this.audio = false;
      this.desk.player.classList.remove('dm-playing');
      this.setCue('desktop');
    }
  }

  /** Scrolls the article under the pointer; false (the page keeps scrolling) anywhere else or at its ends. */
  wheel(px: number, py: number, dy: number): boolean {
    if (!this.manual && this.story === 'full' && (!this.tl || this.tl.time() < LIVE)) return false;
    const [x, y] = this.panelToDesk(px, py);
    const s = this.s;
    const L = this.desk.layout;
    const over = x >= s.sx && x <= s.sx + L.safari.w && y >= s.sy + 52 && y <= s.sy + L.safari.h;
    const next = Math.max(0, Math.min(SCROLL_MAX, s.scroll + dy));
    if (!over || next === s.scroll) return false;
    this.takeOver();
    s.cx = x;
    s.cy = y;
    s.scroll = next;
    if (!this.running) this.render(true);
    return true;
  }
}
