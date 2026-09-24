import './mac.css';

export type DisplayMode = 'extend' | 'mirror';

export interface WinBox {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface Layout {
  w: number;
  h: number;
  menu: number;
  safari: WinBox;
  player: WinBox;
}

/**
 * Extend: a virtual display sized to the car's CSS viewport (TierSelector.displaySize: Theater's page
 * area, 1920×1140 px at DPR 1.53 → 1255×745 pt).
 * Mirror: the Mac's own screen (a 14" MacBook Pro at its default 1512×982 pt, notch menu bar).
 */
export const LAYOUTS: Record<DisplayMode, Layout> = {
  extend: {
    w: 1255,
    h: 745,
    menu: 24,
    safari: { x: 60, y: 64, w: 630, h: 540 },
    player: { x: 606, y: 300, w: 576, h: 324 },
  },
  mirror: {
    w: 1512,
    h: 982,
    menu: 37,
    safari: { x: 70, y: 84, w: 640, h: 600 },
    player: { x: 560, y: 600, w: 560, h: 315 },
  },
};

export interface Desktop {
  root: HTMLDivElement;
  safari: HTMLDivElement;
  page: HTMLDivElement;
  player: HTMLDivElement;
  playerHud: HTMLDivElement;
  /** The film, off-DOM; its frames are drawn into the window's canvas on the stream's frame clock. */
  video: HTMLVideoElement;
  drawFilm(): void;
  /** Back to the poster, film rewound. */
  resetFilm(): void;
  cursor: HTMLDivElement;
  layout: Layout;
  setMode(mode: DisplayMode): void;
  front(win: HTMLElement): void;
  clock(d: Date): void;
}

const STATUS = `
<svg viewBox="0 0 22 16" class="dm-mb-dc"><path d="M6.2 9.3 7.4 6.6c.2-.5.7-.8 1.2-.8h4.8c.5 0 1 .3 1.2.8l1.2 2.7c.6.2 1 .8 1 1.4v2.1c0 .4-.3.7-.7.7h-.9c-.4 0-.7-.3-.7-.7v-.6H7.5v.6c0 .4-.3.7-.7.7h-.9c-.4 0-.7-.3-.7-.7v-2.1c0-.6.4-1.2 1-1.4zm1.4-.1h6.8l-.8-1.9c-.1-.2-.3-.3-.5-.3H8.9c-.2 0-.4.1-.5.3zm.3 2.3a.8.8 0 1 0 0-1.6.8.8 0 0 0 0 1.6zm6.2 0a.8.8 0 1 0 0-1.6.8.8 0 0 0 0 1.6z" fill="currentColor"/><path d="M7.6 3.3a4.9 4.9 0 0 1 6.8 0M9.1 1.3a7 7 0 0 1 3.8 0" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>
<svg viewBox="0 0 18 16"><path d="M2 6.2a10 10 0 0 1 14 0M4.4 8.6a6.6 6.6 0 0 1 9.2 0M6.8 11a3.2 3.2 0 0 1 4.4 0" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="9" cy="13.4" r="1.2" fill="currentColor"/></svg>
<svg viewBox="0 0 16 16"><circle cx="6.6" cy="6.6" r="4.6" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="m10.2 10.2 3.9 3.9" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>
<svg viewBox="0 0 18 16"><rect x="1.2" y="2.4" width="15.6" height="5" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="4.7" cy="4.9" r="1.6" fill="currentColor"/><rect x="1.2" y="8.8" width="15.6" height="5" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="13.3" cy="11.3" r="1.6" fill="currentColor"/></svg>`;

const BATTERY =
  '<svg viewBox="0 0 28 14" class="dm-mb-batt"><rect x=".7" y=".7" width="23.6" height="12.6" rx="3.6" fill="none" stroke="currentColor" stroke-opacity=".45" stroke-width="1.2"/><rect x="2.6" y="2.6" width="15.4" height="8.8" rx="2" fill="currentColor"/><path d="M26 4.8v4.4c.9-.3 1.4-1.2 1.4-2.2s-.5-1.9-1.4-2.2z" fill="currentColor" fill-opacity=".45"/></svg>';

const ARTICLE = `
<header class="dm-pg-nav"><b>Slow Roads</b><span>Routes</span><span>Stops</span><span>Charging</span><span>About</span></header>
<article>
  <p class="dm-pg-kicker">Route notes · Highway 1</p>
  <h1>Big Sur, slowly</h1>
  <p class="dm-pg-lede">Ninety miles of coastline, three good pull-outs, and the charger where the view is better than the coffee.</p>
  <figure class="dm-pg-hero"></figure>
  <h2>Before you go</h2>
  <p>Leave Carmel with a full charge and a loose plan. The road rewards patience: fog sits on the water until late morning, and the light is best on the way back south.</p>
  <p>Most pull-outs fit two or three cars. Park nose-in, leave the engine sound to the waves, and give the cliffs a wide berth.</p>
  <div class="dm-pg-cards"><div><i style="--c1:#1b6fae;--c2:#6ec3d6"></i><b>Bixby Creek</b><span>Mile 13 · 10 min</span></div><div><i style="--c1:#c05a2b;--c2:#f0b35a"></i><b>Pfeiffer Beach</b><span>Mile 31 · 45 min</span></div><div><i style="--c1:#2f6b3f;--c2:#9fcf7a"></i><b>McWay Falls</b><span>Mile 45 · 20 min</span></div></div>
  <h2>The charging stop</h2>
  <p>Plan a long stop at the halfway point. With the car parked and plugged in there is time for lunch, a walk to the overlook, or a film on the big screen while the battery fills.</p>
  <p>Cell coverage comes and goes along the coast, so download what you need before you leave the valley.</p>
  <h2>Coming back</h2>
  <p>Drive the last stretch at golden hour. The turn-outs face west, and every one of them is worth the stop.</p>
</article>`;

export function createDesktop(opts: { wallpaper: Record<DisplayMode, string>; clip: { webm: string; mp4: string; poster: string }}): Desktop {
  const root = document.createElement('div');
  root.className = 'dm-mac';
  root.innerHTML = `
<div class="dm-mac-wall"></div>
<div class="dm-mb">
  <div class="dm-mb-l"><b>Safari</b><span>File</span><span>Edit</span><span>View</span><span>History</span><span>Bookmarks</span><span>Window</span><span>Help</span></div>
  <div class="dm-mb-r">${STATUS}${BATTERY}<span class="dm-mb-clock"></span></div>
</div>
<div class="dm-mw dm-mw-safari">
  <div class="dm-sf-bar">
    <span class="dm-tl"><i></i><i></i><i></i></span>
    <svg class="dm-sf-ic" viewBox="0 0 20 16"><rect x="1" y="1.5" width="18" height="13" rx="3" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M7 1.8v12.4" stroke="currentColor" stroke-width="1.3"/></svg>
    <svg class="dm-sf-ic" viewBox="0 0 30 16"><path d="M9 3 4 8l5 5M21 3l5 5-5 5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>
    <div class="dm-sf-url"><svg viewBox="0 0 10 12"><rect x="1" y="5" width="8" height="6.4" rx="1.4" fill="currentColor"/><path d="M2.8 5V3.6a2.2 2.2 0 0 1 4.4 0V5" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>example.com</div>
    <svg class="dm-sf-ic" viewBox="0 0 16 18"><path d="M8 11.5V1.8M4.6 5 8 1.6 11.4 5M5 8H3.4c-.8 0-1.4.6-1.4 1.4v6c0 .8.6 1.4 1.4 1.4h9.2c.8 0 1.4-.6 1.4-1.4v-6c0-.8-.6-1.4-1.4-1.4H11" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>
    <svg class="dm-sf-ic" viewBox="0 0 16 16"><path d="M8 2v12M2 8h12" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
    <svg class="dm-sf-ic" viewBox="0 0 18 18"><rect x="1.2" y="4.6" width="12.2" height="12.2" rx="2.6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M4.6 2.8c.2-1 1-1.6 2-1.6h8.2c1.1 0 2 .9 2 2V11c0 1-.7 1.8-1.6 2" fill="none" stroke="currentColor" stroke-width="1.3"/></svg>
  </div>
  <div class="dm-sf-view"><div class="dm-sf-page">${ARTICLE}</div></div>
</div>
<div class="dm-mw dm-mw-player">
  <canvas class="dm-qt-film" width="960" height="540"></canvas>
  <div class="dm-qt-title"><span class="dm-tl"><i></i><i></i><i></i></span><span>Coastline.mp4</span></div>
  <div class="dm-qt-hud">
    <svg class="dm-qt-pp" viewBox="0 0 16 16"><path class="dm-qt-play" d="M4.5 2.6v10.8c0 .6.6.9 1.1.6l8.2-5.4c.4-.3.4-.9 0-1.2L5.6 2c-.5-.3-1.1 0-1.1.6z" fill="currentColor"/><path class="dm-qt-pause" d="M4 2.5h2.6v11H4zM9.4 2.5H12v11H9.4z" fill="currentColor"/></svg>
    <span class="dm-qt-t">0:00</span><div class="dm-qt-track"><i></i></div><span class="dm-qt-t">0:10</span>
    <svg viewBox="0 0 18 16"><path d="M2 6h3l4-3.2v10.4L5 10H2z" fill="currentColor"/><path d="M11.6 5.2a4 4 0 0 1 0 5.6M13.8 3.2a6.8 6.8 0 0 1 0 9.6" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>
  </div>
</div>
<div class="dm-mac-cursor"><svg viewBox="0 0 17 25"><path d="M1.5 1.5v18.6l4.6-4.4 3 7.1 3.2-1.4-3-7h6.3z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg></div>`;
  const q = <T extends Element>(s: string) => root.querySelector(s) as T;
  const safari = q<HTMLDivElement>('.dm-mw-safari');
  const player = q<HTMLDivElement>('.dm-mw-player');
  const wall = q<HTMLDivElement>('.dm-mac-wall');
  const filmCanvas = q<HTMLCanvasElement>('.dm-qt-film');
  filmCanvas.style.backgroundImage = `url(${opts.clip.poster})`;
  const film = filmCanvas.getContext('2d')!;
  const video = document.createElement('video');
  video.muted = true;
  video.playsInline = true;
  video.loop = true;
  video.preload = 'none';
  video.innerHTML = `<source src="${opts.clip.webm}" type="video/webm"><source src="${opts.clip.mp4}" type="video/mp4">`;
  const hero = q<HTMLElement>('.dm-pg-hero');
  hero.style.backgroundImage = `url(${opts.clip.poster})`;
  const clockEl = q<HTMLSpanElement>('.dm-mb-clock');
  let z = 10;
  const d: Desktop = {
    root,
    safari,
    page: q('.dm-sf-page'),
    player,
    playerHud: q('.dm-qt-hud'),
    video,
    drawFilm() {
      if (video.readyState < 2) return;
      film.drawImage(video, 0, 0, 960, 540);
    },
    resetFilm() {
      video.pause();
      if (video.readyState >= 1) video.currentTime = 0;
      film.clearRect(0, 0, 960, 540);
    },
    cursor: q('.dm-mac-cursor'),
    layout: LAYOUTS.extend,
    setMode(mode) {
      const L = LAYOUTS[mode];
      d.layout = L;
      root.dataset.mode = mode;
      wall.style.backgroundImage = `url(${opts.wallpaper[mode]})`;
      root.style.width = L.w + 'px';
      root.style.height = L.h + 'px';
      root.style.setProperty('--menu', L.menu + 'px');
      place(safari, L.safari);
      place(player, L.player);
    },
    front(win) {
      win.style.zIndex = String(++z);
      root.querySelectorAll('.dm-mw').forEach((w) => w.classList.toggle('dm-key', w === win));
    },
    clock(date) {
      const day = date.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' }).replace(',', '');
      const time = date.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
      clockEl.textContent = day + ' ' + time;
    },
  };
  d.setMode('extend');
  d.front(safari);
  d.clock(new Date());
  return d;
}

function place(el: HTMLElement, b: WinBox) {
  el.style.width = b.w + 'px';
  el.style.height = b.h + 'px';
  el.style.transform = `translate(${b.x}px, ${b.y}px)`;
}
