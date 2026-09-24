// node secshot.cjs <w> <h> <dpr> <out> <selector> [offsetY] [openFaq]
const puppeteer = require('../../../node_modules/puppeteer-core');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const [W, H, DPR, out, sel, off = '0', openFaq] = process.argv.slice(2);
(async () => {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  const p = await b.newPage(); await p.setViewport({ width: +W, height: +H, deviceScaleFactor: +DPR, isMobile: +W < 600, hasTouch: +W < 1025 });
  await p.goto('http://127.0.0.1:5191/', { waitUntil: 'networkidle2' }); await p.evaluate(() => document.fonts.ready);
  await p.evaluate((sel, off) => { const el = document.querySelector(sel); window.scrollTo(0, el.getBoundingClientRect().top + scrollY - 56 + +off); }, sel, off);
  await sleep(700);
  await p.evaluate(() => { const g = window.__gsap; g && g.globalTimeline.getChildren(true, true, false).forEach((t) => { if (!(t.scrollTrigger && t.scrollTrigger.vars.scrub)) t.progress(1); }); window.__ST && window.__ST.update(); });
  if (openFaq) { await p.evaluate(() => { const b = document.querySelectorAll('.faq__btn'); b[1].click(); b[3].click(); }); await sleep(800); }
  await sleep(600);
  await p.screenshot({ path: out });
  await b.close();
})();
