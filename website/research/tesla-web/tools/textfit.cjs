const puppeteer = require('../../../node_modules/puppeteer-core');
const sizes = [[1512, 945], [1255, 784], [1180, 820], [1024, 1366], [820, 1180], [390, 844], [375, 667]];
(async () => {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  for (const [w, h] of sizes) {
    const p = await b.newPage();
    await p.setViewport({ width: w, height: h, isMobile: w < 600, hasTouch: w < 1025 });
    await p.goto('http://127.0.0.1:5191/', { waitUntil: 'networkidle2' });
    const r = await p.evaluate(() => {
      const lines = (el) => { const lh = parseFloat(getComputedStyle(el).lineHeight) || 20; return Math.round(el.getBoundingClientRect().height / lh); };
      const issues = [];
      for (const el of document.querySelectorAll('.tabs__tab, .nav__item, .btn, .stat__value, .stat__label, .incar__text, .tiers__row > *, .footer__links a, .kicker, .spec__value--num')) {
        if (!el.getBoundingClientRect().width) continue;
        if (el.scrollWidth > el.clientWidth + 1) issues.push('overflow ' + el.className + ' "' + el.textContent.trim().slice(0, 24) + '" ' + el.scrollWidth + '>' + el.clientWidth);
      }
      for (const el of document.querySelectorAll('.stat__value')) if (lines(el) > 1) issues.push('stat wraps "' + el.textContent + '"');
      const titles = [...document.querySelectorAll('.t-hero, .t-section, .t-title, .feature__sub, .hero__sub, .t-sub')].filter((e) => e.getBoundingClientRect().width).map((e) => e.textContent.trim().slice(0, 22) + ':' + lines(e));
      const statRows = [...document.querySelectorAll('.stats')].map((s) => { const r = s.getBoundingClientRect(); return Math.round(r.left) + '..' + Math.round(r.right); });
      return { issues, titles: titles.join(' | '), statRows: statRows.join(' ') };
    });
    console.log(`\n== ${w}x${h}\n issues: ${r.issues.join('; ') || 'none'}\n titles(lines): ${r.titles}\n stat rows x: ${r.statRows}`);
    await p.close();
  }
  await b.close();
})();
