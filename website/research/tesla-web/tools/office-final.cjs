const puppeteer = require('../../../node_modules/puppeteer-core');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  for (const [w, h, dpr, mob, rm, name] of [[1512, 945, 1, false, false, 'd'], [820, 1180, 2, true, false, 't'], [390, 844, 2, true, false, 'p'], [390, 844, 2, true, true, 'p-rm']]) {
    const p = await b.newPage();
    if (rm) await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }]);
    await p.setViewport({ width: w, height: h, deviceScaleFactor: dpr, isMobile: mob, hasTouch: mob });
    await p.goto('http://127.0.0.1:5191/', { waitUntil: 'networkidle2' });
    await p.evaluate(() => { const s = document.getElementById('office'); window.scrollTo(0, s.getBoundingClientRect().top + scrollY - 56); });
    await sleep(rm ? 600 : 5600);
    await p.screenshot({ path: `out/office-${name}.png` });
    await p.close();
  }
  await b.close();
})();
