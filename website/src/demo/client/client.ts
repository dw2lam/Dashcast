import './car-client.css';

/**
 * The Dashcast car client's DOM (Web/src/index.html), one instance per demo screen. `stream` is
 * where the decoded Mac frame goes (the real client's canvas); the demo puts the desktop there.
 */
export interface CarClient {
  root: HTMLDivElement;
  stream: HTMLDivElement;
  pill: HTMLDivElement;
  tap: HTMLDivElement;
  bar: HTMLDivElement;
  kbBtn: HTMLButtonElement;
  fsBtn: HTMLButtonElement;
  stBtn: HTMLButtonElement;
  stats: HTMLDivElement;
  dl: HTMLDListElement;
  modes: HTMLButtonElement[];
  status(text: string | null, cls?: string): void;
  showStats(on: boolean): void;
  renderStats(rows: StatRow[]): void;
  paintMode(mode: 'interactive' | 'cinema' | 'auto'): void;
  resetTap(): void;
  dismissTap(): void;
}

export type StatRow = [string, string, string?];

const html = `
<div class="dm-dcc-v"></div>
<div class="dm-dcc-touch"></div>
<div class="dm-dcc-pill"><i></i><span>Connecting…</span></div>
<div class="dm-dcc-bar">
  <button type="button" aria-label="Keyboard" hidden><svg viewBox="0 0 24 24"><rect x="2.5" y="5.5" width="19" height="13" rx="2.5"/><path d="M6.5 9.5h.01M10 9.5h.01M13.5 9.5h.01M17 9.5h.01M6.5 12.5h.01M10 12.5h.01M13.5 12.5h.01M17 12.5h.01M8 15.5h8"/></svg></button>
  <button type="button" aria-label="Fullscreen"><svg viewBox="0 0 24 24"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></svg></button>
  <button type="button" aria-label="Stats"><svg viewBox="0 0 24 24"><path d="M5 20v-6M12 20V5M19 20v-9"/></svg></button>
</div>
<div class="dm-dcc-panel" hidden>
  <dl></dl>
  <div class="dm-dcc-seg"><button type="button" data-m="interactive">Interactive</button><button type="button" data-m="cinema">Cinema</button><button type="button" data-m="auto">Auto</button></div>
</div>
<div class="dm-dcc-tap">
  <div class="dm-dcc-brand">Dashcast</div>
  <div class="dm-dcc-play"><svg viewBox="0 0 24 24"><path d="M8.5 5.8v12.4c0 .8.9 1.3 1.6.9l9.6-6.2c.6-.4.6-1.3 0-1.7l-9.6-6.2c-.7-.5-1.6 0-1.6.8z"/></svg></div>
  <h1>Tap to start</h1>
  <p>Turns on sound and touch control</p>
</div>`;

export function createCarClient(): CarClient {
  const root = document.createElement('div');
  root.className = 'dm-dcc';
  root.setAttribute('aria-hidden', 'true');
  root.innerHTML = html;
  const q = <T extends Element>(s: string) => root.querySelector(s) as T;
  const pill = q<HTMLDivElement>('.dm-dcc-pill');
  const pillText = pill.querySelector('span')!;
  const tap = q<HTMLDivElement>('.dm-dcc-tap');
  const bar = q<HTMLDivElement>('.dm-dcc-bar');
  const [kbBtn, fsBtn, stBtn] = Array.from(bar.querySelectorAll('button'));
  const stats = q<HTMLDivElement>('.dm-dcc-panel');
  const dl = q<HTMLDListElement>('dl');
  const modes = Array.from(stats.querySelectorAll('.dm-dcc-seg button')) as HTMLButtonElement[];
  root.querySelectorAll('button').forEach((b) => (b.tabIndex = -1));

  return {
    root,
    stream: q('.dm-dcc-v'),
    pill,
    tap,
    bar,
    kbBtn,
    fsBtn,
    stBtn,
    stats,
    dl,
    modes,
    status(text, cls = '') {
      if (text == null) {
        pill.className = 'dm-dcc-pill dm-off';
        return;
      }
      pill.className = 'dm-dcc-pill ' + cls;
      pillText.textContent = text;
    },
    showStats(on) {
      stats.hidden = !on;
      stBtn.classList.toggle('dm-on', on);
    },
    renderStats(rows) {
      dl.innerHTML = rows.map((r) => '<dt>' + r[0] + '</dt><dd class="' + (r[2] || '') + '">' + r[1] + '</dd>').join('');
    },
    paintMode(mode) {
      modes.forEach((b) => b.classList.toggle('dm-on', b.getAttribute('data-m') === mode));
    },
    resetTap() {
      tap.hidden = false;
      tap.classList.remove('dm-off', 'dm-press');
    },
    dismissTap() {
      tap.classList.remove('dm-press');
      tap.classList.add('dm-off');
    },
  };
}
