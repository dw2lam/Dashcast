// ExtendVisual seam check: node research/display/harness/extseam.mjs <outdir>
// The live panel is painted flat black (does anything light show around it?) and flat white (is there a gap
// between it and the bezel?), at the card sizes and DPR 1/2/3. extseam.py measures a ±2 px ring across its edge.
import puppeteer from 'puppeteer-core';
import { writeFileSync } from 'node:fs';

const [out] = process.argv.slice(2);
const browser = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio', '--hide-scrollbars'] });
const rows = [];
for (const [w, h] of [[720, 508], [358, 201], [640, 360]]) {
  for (const dpr of [1, 2, 3]) {
    for (const paint of ['black', 'white', 'live']) {
      const page = await browser.newPage();
      await page.setViewport({ width: w + 40, height: h + 40, deviceScaleFactor: dpr });
      await page.goto(`http://127.0.0.1:5184/research/display/harness/index.html?vis=extend&w=${w}&h=${h}`, { waitUntil: 'networkidle0' });
      await page.evaluate(() => document.querySelector('.dm-ev-photo').decode().catch(() => {}));
      if (paint !== 'live')
        await page.addStyleTag({ content: `.dm-ev-panel{background:${paint}!important;filter:none!important}.dm-ev-panel>*,.dm-ev-panel::after{visibility:hidden!important}` });
      await new Promise((r) => setTimeout(r, 500));
      const quad = await page.evaluate(() => {
        const p = document.querySelector('.dm-ev-panel');
        const host = document.querySelector('.dm-ev').getBoundingClientRect();
        const world = new DOMMatrix(getComputedStyle(document.querySelector('.dm-ev-world')).transform);
        const m = world.multiply(new DOMMatrix(getComputedStyle(p).transform));
        return [[0, 0], [1920, 0], [1920, 1200], [0, 1200]].map(([x, y]) => {
          const q = m.transformPoint(new DOMPoint(x, y, 0, 1));
          return [host.left + q.x / q.w - 20, host.top + q.y / q.w - 20];
        });
      });
      const file = `${out}/ext-${paint}-${w}x${h}@${dpr}.png`;
      await page.screenshot({ path: file, clip: { x: 20, y: 20, width: w, height: h } });
      rows.push({ w, h, dpr, paint, file, quad });
      await page.close();
    }
  }
}
writeFileSync(`${out}/ext.json`, JSON.stringify(rows));
await browser.close();
console.log(rows.length, 'renders');
