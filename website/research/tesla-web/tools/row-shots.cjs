const puppeteer = require('../../../node_modules/puppeteer-core');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  for (const [w, h, dpr, mob, tag] of [[1512, 945, 1, false, 'd'], [390, 844, 2, true, 'p'], [820, 1180, 2, true, 't']]) {
    const p = await b.newPage(); await p.setViewport({ width: w, height: h, deviceScaleFactor: dpr, isMobile: mob, hasTouch: mob });
    await p.goto('http://127.0.0.1:5191/', { waitUntil: 'networkidle2' });
    await p.evaluate(() => { const s = document.getElementById('features'); window.scrollTo(0, s.getBoundingClientRect().top + scrollY - 56); });
    await sleep(800);
    await p.evaluate(() => { const g = window.__gsap; g && g.globalTimeline.getChildren(true, true, false).forEach((t) => { if (!(t.scrollTrigger && t.scrollTrigger.vars.scrub)) t.progress(1); }); });
    for (const i of [1, 2]) {
      await p.evaluate((i) => document.querySelectorAll('.srow__dot')[i].click(), i);
      await sleep(1100);
      await p.screenshot({ path: `out/r6-${tag}-card${i}.png` });
    }
    await p.close();
  }
  await b.close();
})();
