const puppeteer = require('../../../node_modules/puppeteer-core');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  const p = await b.newPage(); await p.setViewport({ width: 1200, height: 800 });
  await p.goto('http://127.0.0.1:5191/', { waitUntil: 'networkidle2' });
  await p.evaluate(() => { const s = document.querySelector('.office__scene'); window.scrollTo(0, s.getBoundingClientRect().top + scrollY - 120); });
  const t0 = Date.now();
  const clip = await p.evaluate(() => { const r = document.querySelector('.office__scene').getBoundingClientRect(); return { x: r.left, y: r.top + scrollY, width: r.width, height: r.height }; });
  for (const t of [300, 1200, 2000, 2800, 3500, 4200, 5200]) {
    await sleep(Math.max(0, t - (Date.now() - t0)));
    await p.screenshot({ path: `out/office-t${t}.png`, clip });
  }
  await b.close();
})();
