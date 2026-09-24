// Alignment check: node research/display/harness/align.mjs <outdir> <w> <h> [dpr] [query]
// 1. numeric: the glass element's matrix3d corners vs the photo's measured corners mapped through the
//    rendered <img> rect (px error per corner);
// 2. pixels: the photo's own screen (glass hidden) vs the composited panel painted solid, edge found
//    along each side of each corner; writes zoomed corner crops of both for eyeballing.
import puppeteer from 'puppeteer-core';
import { writeFileSync } from 'node:fs';

const [out, w, h, dpr = '1', query = 'only=hero&still'] = process.argv.slice(2);
const browser = await puppeteer.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true,
  args: ['--mute-audio', '--hide-scrollbars'],
});
const page = await browser.newPage();
await page.setViewport({ width: +w, height: +h, deviceScaleFactor: +dpr });
await page.goto('http://127.0.0.1:5184/research/display/harness/index.html?' + query, { waitUntil: 'networkidle0' });
await page.evaluate(() => document.querySelector('.dm-stg-photo').decode());
await new Promise((r) => setTimeout(r, 600));
const res = await page.evaluate(async () => {
  const { PHOTO } = await import('/src/demo/photo.ts');
  const host = document.querySelector('.dm-stg').parentElement;
  const hr = host.getBoundingClientRect();
  const img = document.querySelector('.dm-stg-photo');
  const ir = img.getBoundingClientRect();
  const k = ir.width / PHOTO.width;
  const want = PHOTO.quad.map(([x, y]) => [ir.left - hr.left + x * k, ir.top - hr.top + y * k]);
  const glass = document.querySelector('.dm-stg-glass');
  const m = new DOMMatrix(getComputedStyle(glass).transform);
  const got = [[0, 0], [1920, 0], [1920, 1200], [0, 1200]].map(([x, y]) => {
    const p = m.transformPoint(new DOMPoint(x, y, 0, 1));
    return [p.x / p.w, p.y / p.w];
  });
  const err = got.map((g, i) => Math.hypot(g[0] - want[i][0], g[1] - want[i][1]));
  return { host: [hr.width, hr.height], screenW: Math.hypot(want[1][0] - want[0][0], want[1][1] - want[0][1]), want, got, err };
});
console.log(JSON.stringify(res));
await page.addStyleTag({ content: '.dm-stg-glass{visibility:hidden!important}' });
await new Promise((r) => setTimeout(r, 300));
await page.screenshot({ path: `${out}/photo-${w}x${h}@${dpr}.png` });
await page.addStyleTag({ content: '.dm-stg-glass{visibility:visible!important}.dm-stg-glass *{visibility:hidden!important}.dm-tsl{visibility:visible!important;background:#f0f!important}' });
await new Promise((r) => setTimeout(r, 300));
await page.screenshot({ path: `${out}/mask-${w}x${h}@${dpr}.png` });
writeFileSync(`${out}/quad-${w}x${h}@${dpr}.json`, JSON.stringify(res));
await browser.close();
