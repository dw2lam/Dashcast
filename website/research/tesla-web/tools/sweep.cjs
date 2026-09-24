// Contact sheets + measurements per viewport. Dev server on :5191, then: node sweep.cjs <label> <w> <h> [dpr] [ua]
// Usage: node sweep.cjs <label> <w> <h> [dpr] [ua] [url]
const puppeteer = require('../../../node_modules/puppeteer-core');
const fs = require('fs');
const path = require('path');
const [label, W, H, DPR = '1', UA = '', URL = 'http://127.0.0.1:5191/'] = process.argv.slice(2);
const out = path.join(__dirname, 'out', label);
fs.mkdirSync(out, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio', '--autoplay-policy=no-user-gesture-required'] });
  const p = await b.newPage();
  const errors = [];
  p.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  p.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  p.on('requestfailed', (r) => errors.push('reqfail: ' + r.url() + ' ' + (r.failure() && r.failure().errorText)));
  if (UA) await p.setUserAgent(UA);
  await p.setViewport({ width: +W, height: +H, deviceScaleFactor: +DPR, isMobile: +W < 600, hasTouch: +W < 1025 });
  await p.goto(URL, { waitUntil: 'networkidle2', timeout: 60000 });
  await p.evaluate(() => document.fonts.ready);
  await sleep(800);
  const finish = () => p.evaluate(() => {
    const g = window.__gsap;
    if (!g) return;
    g.globalTimeline.getChildren(true, true, false).forEach((t) => {
      const st = t.scrollTrigger;
      if (st && st.vars && st.vars.scrub) return;
      if (st && !st.isActive && st.progress === 0 && st.start > window.scrollY + window.innerHeight) return;
      t.progress(1);
    });
    window.__ST && window.__ST.update();
  });
  const total = await p.evaluate(() => document.documentElement.scrollHeight);
  const step = Math.round(+H * 0.85);
  const shots = [];
  for (let y = 0, i = 0; y < total; y += step, i++) {
    await p.evaluate((y) => window.scrollTo(0, y), y);
    await sleep(350);
    await finish();
    await sleep(250);
    const f = path.join(out, `s${String(i).padStart(2, '0')}.png`);
    await p.screenshot({ path: f });
    shots.push(f);
    if (y + +H >= total) break;
  }
  // measurements at the end (all reveals done)
  const m = await p.evaluate((isPhone) => {
    const de = document.documentElement;
    const res = { scrollWidth: de.scrollWidth, clientWidth: de.clientWidth, height: de.scrollHeight, small: [], taps: [], wide: [] };
    const vis = (el) => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none' && +cs.opacity !== 0; };
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const seen = new Set();
    let n;
    while ((n = walker.nextNode())) {
      if (!n.textContent.trim()) continue;
      const el = n.parentElement;
      if (seen.has(el) || !vis(el)) continue;
      seen.add(el);
      const fs = parseFloat(getComputedStyle(el).fontSize);
      if (isPhone && fs < 11) res.small.push(`${fs}px "${n.textContent.trim().slice(0, 40)}"`);
    }
    for (const el of document.querySelectorAll('a, button, [role=tab]')) {
      if (!vis(el) || el.closest('[aria-hidden=true]')) continue;
      const r = el.getBoundingClientRect();
      if (r.height < 40 || r.width < 40) res.taps.push(`${Math.round(r.width)}x${Math.round(r.height)} ${el.tagName} "${(el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 30)}"`);
    }
    for (const el of document.querySelectorAll('body *')) {
      const r = el.getBoundingClientRect();
      if (r.width && (r.right > de.clientWidth + 1 || r.left < -1)) {
        let p = el.parentElement, clipped = false;
        while (p) { const o = getComputedStyle(p).overflowX; if (o === 'hidden' || o === 'clip') { const pr = p.getBoundingClientRect(); if (pr.right <= de.clientWidth + 1 && pr.left >= -1) { clipped = true; break; } } p = p.parentElement; }
        if (!clipped) res.wide.push(`${el.tagName}.${String(el.className).slice(0, 40)} ${Math.round(r.left)}..${Math.round(r.right)}`);
      }
    }
    res.wide = res.wide.slice(0, 12);
    return res;
  }, +W < 600);
  // contact sheet
  const cols = +W >= 1000 ? 3 : +W >= 700 ? 4 : 6;
  const imgs = shots.map((f) => 'data:image/png;base64,' + fs.readFileSync(f).toString('base64'));
  const sheet = await b.newPage();
  const cellW = Math.round(1800 / cols);
  await sheet.setViewport({ width: 1800, height: 1000 });
  await sheet.setContent(`<body style="margin:0;background:#888;display:grid;grid-template-columns:repeat(${cols},${cellW - 6}px);gap:6px;padding:6px">${imgs.map((s, i) => `<div style="position:relative"><img src="${s}" style="width:100%;display:block"><b style="position:absolute;top:2px;left:4px;font:12px Menlo;color:#f0f;background:#fff">${i}</b></div>`).join('')}</body>`);
  await sheet.screenshot({ path: path.join(__dirname, 'out', `${label}-sheet.png`), fullPage: true });
  console.log(JSON.stringify({ label, W, H, shots: shots.length, errors: [...new Set(errors)].slice(0, 12), ...m }, null, 1));
  await b.close();
})();
