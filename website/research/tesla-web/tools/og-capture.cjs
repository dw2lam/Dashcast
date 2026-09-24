// og.png from the real hero: the demo's cabin composite in capture mode (?capture=1), a 1200×630 band cropped
// from a 1200×900 render (so the car screen is larger), with the mark, title, subtitle and stats laid over it.
// Needs the dev server: npx vite --port 5191 --strictPort. Usage: node og-capture.cjs [seekSeconds]
const puppeteer = require('../../../node_modules/puppeteer-core');
const { execFileSync } = require('child_process');
const path = require('path');
const T = Number(process.argv[2] || 0);
const W = 1200;
const H = 900;
const CROP = { x: 0, y: 178, width: 1200, height: 630 };

const overlay = (crop) => `
<style>
  .og { position: fixed; left: 0; right: 0; top: ${crop.y}px; height: ${crop.height}px; z-index: 2147483647; pointer-events: none;
        font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; color: #fff; -webkit-font-smoothing: antialiased; }
  .og-scrim { position: absolute; inset: 0; background:
      linear-gradient(to bottom, rgba(0,0,0,.82), rgba(0,0,0,.5) 26%, rgba(0,0,0,0) 46%),
      linear-gradient(to top, rgba(0,0,0,.85), rgba(0,0,0,.35) 22%, rgba(0,0,0,0) 36%); }
  .og-top { position: absolute; top: 34px; left: 0; right: 0; text-align: center; }
  .og-brand { display: inline-flex; align-items: center; gap: 14px; }
  .og h1 { margin: 0; font-weight: 500; font-size: 72px; line-height: 1; letter-spacing: -0.015em; }
  .og p { margin: 8px 0 0; font-size: 24px; line-height: 30px; color: rgba(255,255,255,.92); }
  .og-stats { position: absolute; left: 0; right: 0; bottom: 30px; display: flex; justify-content: center; }
  .og-s { padding: 0 34px; text-align: center; } .og-s + .og-s { border-left: 1px solid rgba(255,255,255,.3); }
  .og-v { font-weight: 500; font-size: 38px; line-height: 44px; letter-spacing: -0.01em; white-space: nowrap; }
  .og-u { font-size: 19px; margin-left: 4px; }
  .og-l { font-size: 15px; line-height: 20px; color: rgba(255,255,255,.8); }
  .og-url { position: absolute; top: 22px; right: 28px; font-size: 15px; font-weight: 500; color: rgba(255,255,255,.7); }
  .dm-snd { display: none !important; }
</style>
<div class="og">
  <div class="og-scrim"></div>
  <div class="og-url">dashcast.davidlam.online</div>
  <div class="og-top">
    <div class="og-brand">
      <svg width="67" height="48" viewBox="0 0 28 20"><defs><linearGradient id="ogg" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#0872FE"/><stop offset=".55" stop-color="#15ABFE"/><stop offset="1" stop-color="#18D3FD"/></linearGradient></defs><rect x="6" y="2" width="21" height="10.5" rx="2.2" fill="url(#ogg)"/><rect x="1" y="8" width="13.2" height="9.4" rx="1.9" fill="#fff" stroke="#8A96AB" stroke-opacity=".55" stroke-width=".8"/><rect x="2.7" y="9.7" width="9.8" height="6" rx=".9" fill="url(#ogg)"/></svg>
      <h1>Dashcast</h1>
    </div>
    <p>Your Mac, on your Tesla&rsquo;s screen.</p>
  </div>
  <div class="og-stats">
    <div class="og-s"><div class="og-v">60<span class="og-u">fps</span></div><div class="og-l">on MCU3</div></div>
    <div class="og-s"><div class="og-v">HEVC</div><div class="og-l">or H.264</div></div>
    <div class="og-s"><div class="og-v">48<span class="og-u">kHz</span></div><div class="og-l">stereo, in sync</div></div>
    <div class="og-s"><div class="og-v">0</div><div class="og-l">cloud servers</div></div>
  </div>
</div>`;

(async () => {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  const p = await b.newPage();
  await p.setViewport({ width: W, height: H, deviceScaleFactor: 2 });
  await p.goto('http://127.0.0.1:5191/?capture=1&framing=hero', { waitUntil: 'networkidle0', timeout: 60000 });
  await p.waitForFunction(() => window.__dashcastCapture, { timeout: 30000 });
  await p.evaluate(() => window.__dashcastCapture.ready);
  await p.evaluate((t) => window.__dashcastCapture.seek(t), T);
  await p.evaluate((html) => document.body.insertAdjacentHTML('beforeend', html), overlay(CROP));
  await new Promise((r) => setTimeout(r, 300));
  const tmp = path.join(__dirname, 'og@2x.png');
  await p.screenshot({ path: tmp, clip: CROP });
  await b.close();
  const out = path.join(__dirname, '../../../public/og.png');
  execFileSync('python3', ['-c', `from PIL import Image; Image.open('${tmp}').convert('RGB').resize((1200,630), Image.LANCZOS).save('${out}', optimize=True)`]);
  require('fs').unlinkSync(tmp);
  console.log('wrote', out);
})();
