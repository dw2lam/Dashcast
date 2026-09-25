// #app entry + pinned frames with the gaps that make up its heading unit.
// node app-frames.cjs <w> <h> <label>   (dev server on :5191; writes out/app-<label>-<frame>.png)
const puppeteer = require('../../../node_modules/puppeteer-core');
const path = require('path');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const [W, H, label] = process.argv.slice(2);
(async () => {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  const p = await b.newPage();
  await p.setViewport({ width: +W, height: +H, deviceScaleFactor: 1, isMobile: +W < 600, hasTouch: +W < 1025 });
  await p.goto('http://127.0.0.1:5191/', { waitUntil: 'networkidle2', timeout: 60000 });
  await p.evaluate(() => document.fonts.ready);
  // The rise runs from "section top at 92% of the viewport" to "top at 8%"; the pin starts at top = nav height.
  const geo = await p.evaluate(() => {
    const s = document.getElementById('app');
    const top = s.getBoundingClientRect().top + scrollY;
    return { top, vh: innerHeight };
  });
  const at = (f) => Math.round(geo.top - geo.vh * (0.92 - 0.84 * f));
  const frames = [
    ['e000', at(0)],
    ['e030', at(0.3)],
    ['e060', at(0.6)],
    ['e100', at(1)],
  ];
  for (const [name, y] of frames) {
    await p.evaluate((y) => window.scrollTo(0, y), y);
    await sleep(900);
    frames.find((f) => f[0] === name).push(await measure());
    await p.screenshot({ path: path.join(__dirname, 'out', `app-${label}-${name}.png`) });
  }
  // pinned: a little into the pin
  const pinY = await p.evaluate(() => {
    const st = window.__ST.getAll().find((t) => t.pin && t.trigger.classList.contains('sc__pin'));
    return st ? Math.round(st.start + (st.end - st.start) * 0.1) : 0;
  });
  await p.evaluate((y) => window.scrollTo(0, y), pinY);
  await sleep(1400);
  frames.push(['pinned', pinY, await measure()]);
  await p.screenshot({ path: path.join(__dirname, 'out', `app-${label}-pinned.png`) });
  for (const [name, y, m] of frames) console.log(`${label} ${name.padEnd(6)} y${y} ${m}`);
  await b.close();

  function measure() {
    return p.evaluate(() => {
      const r = (sel) => document.querySelector(sel).getBoundingClientRect();
      const t = r('#app-title');
      const sub = r('#app .sc__head .t-sub');
      const st = document.querySelector('.sc__stage');
      const sr = st.getBoundingClientRect();
      const clip = getComputedStyle(st).clipPath;
      const m = /inset\(([\d.]+)(px|%)(?: ([\d.]+)(px|%))?(?: ([\d.]+)(px|%))?/.exec(clip);
      let insetTop = 0;
      let insetBottom = 0;
      if (m) {
        const v = (n, u, base) => (u === '%' ? (base * parseFloat(n)) / 100 : parseFloat(n));
        insetTop = v(m[1], m[2], sr.height);
        insetBottom = m[5] ? v(m[5], m[6], sr.height) : insetTop;
      }
      const c = r('.sc__controls');
      const pin = r('.sc__pin');
      const box = r('.sc__box');
      const visTop = sr.top + insetTop;
      return `title@${Math.round(t.top)} nav→title ${Math.round(t.top - 56)} | title→sub ${Math.round(sub.top - t.bottom)} | sub→stage(box) ${Math.round(sr.top - sub.bottom)} sub→stage(visible) ${Math.round(visTop - sub.bottom)} | stage ${Math.round(sr.width)}x${Math.round(sr.height)} in box ${Math.round(box.width)}x${Math.round(box.height)} | stage→controls ${Math.round(c.top - (sr.bottom))} | controls→pin end ${Math.round(pin.bottom - c.bottom)} | clip ${clip.replace(/ round.*/, ')')} insetT ${Math.round(insetTop)}`;
    });
  }
})();
