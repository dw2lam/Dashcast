// Section-by-section spacing audit. Dev server on :5191, then: node audit.cjs <w> <h> [json-out]
// Prints, per section: padding, title offset and type, title→sub and head→content gaps, content x/width,
// first card radius, and the visible air between the previous section's last content and this title.
const puppeteer = require('../../../node_modules/puppeteer-core');
const fs = require('fs');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const [W, H, jsonOut] = process.argv.slice(2);
(async () => {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  const p = await b.newPage();
  await p.setViewport({ width: +W, height: +H, deviceScaleFactor: 1, isMobile: +W < 600, hasTouch: +W < 1025 });
  await p.goto('http://127.0.0.1:5191/', { waitUntil: 'networkidle2', timeout: 60000 });
  await p.evaluate(() => document.fonts.ready);
  const total = await p.evaluate(() => document.documentElement.scrollHeight);
  for (let y = 0; y < total; y += +H) {
    await p.evaluate((y) => window.scrollTo(0, y), y);
    await sleep(120);
  }
  await p.evaluate(() => window.scrollTo(0, 0));
  await sleep(400);
  await p.evaluate(() => {
    const g = window.__gsap;
    g.globalTimeline.getChildren(true, true, false).forEach((t) => {
      if (!(t.scrollTrigger && t.scrollTrigger.vars.scrub)) t.progress(1);
    });
    document.querySelectorAll('[data-reveal]').forEach((e) => { e.style.transform = 'none'; e.style.opacity = '1'; });
    window.__ST.update();
  });
  await sleep(300);
  const rows = await p.evaluate(() => {
    const Y = (e) => e.getBoundingClientRect().top + scrollY;
    const B = (e) => e.getBoundingClientRect().bottom + scrollY;
    const vis = (e) => {
      const r = e.getBoundingClientRect();
      const cs = getComputedStyle(e);
      return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none';
    };
    const secs = [...document.querySelectorAll('main > section, main > div > section, body > #root > section, footer, .closing')]
      .filter((s, i, a) => a.indexOf(s) === i && !a.some((o) => o !== s && o.contains(s)));
    const lastContent = (s) => {
      let m = 0;
      s.querySelectorAll('h1,h2,h3,p,li,img,svg,button,a,video,canvas,.split,.card,.tile').forEach((e) => {
        if (vis(e) && e.closest('.pin-spacer') !== e) m = Math.max(m, B(e));
      });
      return m;
    };
    let prevBottom = null;
    return secs.map((s) => {
      const cs = getComputedStyle(s);
      const top = Y(s);
      const t = s.querySelector('.t-section, h2');
      const row = { id: s.id || s.className.split(' ')[0], top: Math.round(top), h: Math.round(s.getBoundingClientRect().height), pt: cs.paddingTop, pb: cs.paddingBottom, bg: cs.backgroundColor };
      if (t && vis(t)) {
        const tc = getComputedStyle(t);
        row.title = `${tc.fontSize}/${tc.lineHeight} w${tc.fontWeight} ${tc.textAlign}`;
        row.tY = Math.round(Y(t) - top);
        row.tX = Math.round(t.getBoundingClientRect().left);
        const head = t.closest('header') || t.parentElement;
        const sub = head.querySelector('.t-sub');
        if (sub && vis(sub)) {
          const sc = getComputedStyle(sub);
          row.sub = `${sc.fontSize}/${sc.lineHeight}`;
          row.tSub = Math.round(Y(sub) - B(t));
        }
        let n = head.nextElementSibling;
        while (n && !vis(n)) n = n.nextElementSibling;
        if (n) {
          row.headToContent = Math.round(Y(n) - B(head));
          row.content = `${n.className.split(' ')[0]} x${Math.round(n.getBoundingClientRect().left)} w${Math.round(n.getBoundingClientRect().width)}`;
        }
        if (prevBottom != null) row.air = Math.round(Y(t) - prevBottom);
      }
      const card = [...s.querySelectorAll('*')].find((e) => {
        const r = e.getBoundingClientRect();
        return r.width > 120 && r.height > 120 && parseFloat(getComputedStyle(e).borderTopLeftRadius) > 0 && vis(e);
      });
      if (card) row.radius = `${getComputedStyle(card).borderTopLeftRadius} (${card.className.split(' ')[0]})`;
      prevBottom = lastContent(s);
      row.lastB = Math.round(prevBottom - top);
      return row;
    });
  });
  if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify(rows, null, 1));
  for (const r of rows) {
    console.log(
      `${r.id.padEnd(10)} top${r.top} h${r.h} pad ${r.pt}/${r.pb} | title ${r.title || '-'} @${r.tY ?? '-'} x${r.tX ?? '-'} | sub ${r.sub || '-'} gap ${r.tSub ?? '-'} | head→content ${r.headToContent ?? '-'} ${r.content || ''} | r ${r.radius || '-'} | air ${r.air ?? '-'} | lastB ${r.lastB}`,
    );
  }
  await b.close();
})();
