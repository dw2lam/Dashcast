// Seam check: does the photo's own screen show around the composited panel?
//   node research/display/harness/seam.mjs <outdir> [label]
// For each framing × viewport × DPR (plus mid-morph and mid-Theater frames) it paints the live panel
// solid black, hides the emissive glow, screenshots a clip around the panel and writes the panel quad
// (CSS px) next to it. seam.py then samples a ring straddling the panel edge.
import puppeteer from 'puppeteer-core';
import { writeFileSync } from 'node:fs';

const [out, label = 'run'] = process.argv.slice(2);
const BASE = 'http://127.0.0.1:5184/research/display/harness/index.html';
const BLACK = '.dm-stg-glass .dm-tsl{background:#000!important}.dm-stg-glass .dm-tsl>*{visibility:hidden!important}.dm-stg-glow{visibility:hidden!important}';
const sizes = [[1512, 945], [1920, 1080], [3840, 2160], [390, 844]];
const cases = [];
for (const framing of ['hero', 'section']) for (const [w, h] of sizes) for (const dpr of [1, 2, 3]) cases.push({ framing, w, h, dpr, state: 'rest' });
for (const dpr of [1, 2, 3]) {
  cases.push({ framing: 'section', w: 1512, h: 945, dpr, state: 'morph' });
  cases.push({ framing: 'section', w: 1512, h: 945, dpr, state: 'theater' });
}

const browser = await puppeteer.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true,
  args: ['--mute-audio', '--hide-scrollbars'],
});
const results = [];
for (const c of cases) {
  const page = await browser.newPage();
  await page.setViewport({ width: c.w, height: c.h, deviceScaleFactor: c.dpr });
  await page.goto(BASE + (c.framing === 'hero' ? '?only=hero' : '?only=demo'), { waitUntil: 'networkidle0' });
  if (c.framing === 'section') {
    await page.evaluate(() => window.scrollTo(0, document.querySelector('.dm-demo-stage').getBoundingClientRect().top + scrollY - 20));
    await new Promise((r) => setTimeout(r, 600));
  }
  await page.evaluate(() => document.querySelector('.dm-stg-photo').decode().catch(() => {}));
  await page.evaluate(async (state) => {
    const g = (await window.__gsap).default;
    const tls = () => g.globalTimeline.getChildren(false, false, true).filter((t) => t.duration() > 9);
    for (const tl of tls()) {
      tl.pause();
      tl.time(state === 'theater' ? 4.45 : 5, false);
    }
    if (state === 'morph') {
      [...document.querySelectorAll('.dm-seg button')].find((b) => b.textContent === 'Screen').click();
      await new Promise((r) => setTimeout(r, 50));
      const tw = g.globalTimeline.getChildren(false, true, false).find((t) => Math.abs(t.duration() - 1.1) < 0.01);
      tw.pause();
      tw.progress(0.5);
    }
  }, c.state);
  await page.addStyleTag({ content: BLACK });
  await new Promise((r) => setTimeout(r, 400));
  const q = await page.evaluate(() => {
    const glass = document.querySelector('.dm-stg-glass');
    const host = glass.closest('.dm-cab').getBoundingClientRect();
    const m = new DOMMatrix(getComputedStyle(glass).transform);
    return [[0, 0], [1920, 0], [1920, 1200], [0, 1200]].map(([x, y]) => {
      const p = m.transformPoint(new DOMPoint(x, y, 0, 1));
      return [host.left + p.x / p.w, host.top + p.y / p.w];
    });
  });
  const xs = q.map((p) => p[0]);
  const ys = q.map((p) => p[1]);
  const clip = { x: Math.max(0, Math.min(...xs) - 16), y: Math.max(0, Math.min(...ys) - 16) };
  clip.width = Math.min(c.w, Math.max(...xs) + 16) - clip.x;
  clip.height = Math.min(c.h, Math.max(...ys) + 16) - clip.y;
  const file = `${out}/${label}-${c.framing}-${c.state}-${c.w}x${c.h}@${c.dpr}.png`;
  await page.screenshot({ path: file, clip: { ...clip, y: clip.y + (await page.evaluate(() => scrollY)) } });
  results.push({ ...c, file, clip, quad: q });
  await page.close();
}
writeFileSync(`${out}/${label}.json`, JSON.stringify(results));
await browser.close();
console.log(results.length, 'renders');
