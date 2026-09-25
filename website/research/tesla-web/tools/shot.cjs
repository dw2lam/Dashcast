// node shot.cjs <w> <h> <dpr> <out> <selector> [offsetY] [waitMs] — scroll the selector to just under the nav, wait, screenshot the viewport.
const puppeteer = require('../../../node_modules/puppeteer-core');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const [W, H, DPR, out, sel, off = '0', wait = '1500'] = process.argv.slice(2);
(async () => {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  const p = await b.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  await p.setViewport({ width: +W, height: +H, deviceScaleFactor: +DPR, isMobile: +W < 600, hasTouch: +W < 1025 });
  await p.goto('http://127.0.0.1:5191/', { waitUntil: 'networkidle2', timeout: 60000 });
  await p.evaluate(() => document.fonts.ready);
  await p.evaluate((sel, off) => { const el = document.querySelector(sel); window.scrollTo(0, el.getBoundingClientRect().top + scrollY - 56 + +off); }, sel, off);
  await sleep(+wait);
  await p.screenshot({ path: out });
  if (errs.length) console.log('errors', errs.slice(0, 5));
  await b.close();
})();
