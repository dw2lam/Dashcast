const puppeteer = require('../../../node_modules/puppeteer-core');
const sizes = [[1920, 1080], [1512, 945], [1440, 900], [1255, 784], [1180, 820], [1024, 1366], [820, 1180], [390, 844], [375, 667]];
(async () => {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  for (const [w, h] of sizes) {
    const p = await b.newPage();
    await p.setViewport({ width: w, height: h, isMobile: w < 600, hasTouch: w < 1025 });
    await p.goto('http://127.0.0.1:5191/', { waitUntil: 'networkidle2' });
    await p.evaluate(() => { document.querySelectorAll('.faq__btn').forEach((b) => b.click()); });
    await new Promise((r) => setTimeout(r, 700));
    const r = await p.evaluate(() => {
      const issues = [];
      const sel = '.split__title, .split__sub, .split__value, .split__label, .card__title, .card__label, .cmp__name, .cmp__label, .cmp__value, .cmp__note, .faq__title, .faq__a, .faq__heading, .tabs__tab, .nav__item, .btn, .stat__value, .stat__label, .t-section, .t-sub, .compare__foot, .card__detail, .office__title, .office__body, .office__note, .band__title, .foot__mark, .foot__tag, .foot__links a, .foot__legal, .closing__meta';
      for (const el of document.querySelectorAll(sel)) {
        const rr = el.getBoundingClientRect();
        if (!rr.width) continue;
        if (el.scrollWidth > el.clientWidth + 1) issues.push('overflow ' + el.className.toString().split(' ')[0] + ' "' + el.textContent.trim().slice(0, 24) + '"');
        let a = el.parentElement;
        while (a && a !== document.body) {
          const cs = getComputedStyle(a);
          if (cs.overflow === 'hidden' || cs.overflowX === 'hidden') {
            const ar = a.getBoundingClientRect();
            if (!a.classList.contains('cards__track') && (rr.right > ar.right + 1 || rr.left < ar.left - 1)) { issues.push('clipped ' + el.className.toString().split(' ')[0] + ' "' + el.textContent.trim().slice(0, 24) + '" by ' + a.className.toString().split(' ')[0]); break; }
          }
          a = a.parentElement;
        }
      }
      const small = [...document.querySelectorAll('#extend *, #touch *, #compare *, #faq *, #office *, .band *, .closing *')].filter((e) => e.children.length === 0 && e.textContent.trim() && e.getBoundingClientRect().width && parseFloat(getComputedStyle(e).fontSize) < 11).map((e) => e.textContent.trim().slice(0, 20));
      const taps = [...document.querySelectorAll('#extend a, #touch button, #compare a, #faq button, .nav a, .nav button, .closing a')].filter((e) => { const rr = e.getBoundingClientRect(); return rr.width && getComputedStyle(e).display !== 'none' && (rr.height < 40 || rr.width < 40); }).map((e) => (e.textContent.trim() || e.getAttribute('aria-label')).slice(0, 16) + ' ' + Math.round(e.getBoundingClientRect().width) + 'x' + Math.round(e.getBoundingClientRect().height));
      return { issues: [...new Set(issues)], small, taps, hs: document.documentElement.scrollWidth === document.documentElement.clientWidth };
    });
    console.log(`${w}x${h} noHScroll:${r.hs} issues:${r.issues.join('; ') || 'none'} small:${r.small.join(',') || 'none'} taps<40:${r.taps.join(', ') || 'none'}`);
    await p.close();
  }
  await b.close();
})();
