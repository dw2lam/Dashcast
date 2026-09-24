const puppeteer = require('../../../node_modules/puppeteer-core');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function run(view, label, TRACK) {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  const p = await b.newPage();
  await p.setViewport(view);
  await p.goto('http://127.0.0.1:5191/', { waitUntil: 'networkidle2' });
  await p.evaluate(() => document.fonts.ready);
  await p.evaluate((t) => (window.__TRACK = t), TRACK);
  const center = async () => {
    await p.evaluate(() => { const t = document.getElementById(window.__TRACK); window.scrollTo(0, t.getBoundingClientRect().top + scrollY - 200); });
    await sleep(400);
    return p.evaluate(() => { const r = document.getElementById(window.__TRACK).getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; });
  };
  const reset = async () => { await p.evaluate(() => { document.getElementById(window.__TRACK).scrollLeft = 0; }); await sleep(300); };
  const state = () => p.evaluate(() => { const t = document.getElementById(window.__TRACK); const cards = [...t.querySelectorAll('.card, .split')]; const f = cards[0].offsetLeft; const snaps = cards.map((c) => Math.min(t.scrollWidth - t.clientWidth, c.offsetLeft - f)); return { left: Math.round(t.scrollLeft), snapped: snaps.some((s) => Math.abs(s - t.scrollLeft) < 2), pageY: Math.round(scrollY) }; });
  const log = (name, a, z, extra = '') => console.log(`${label} ${name}`.padEnd(40), `scrollLeft ${a.left} → ${z.left}`.padEnd(24), `snapped:${z.snapped}`, `pageY ${a.pageY}→${z.pageY}`, extra);
  let box, a, z;

  if (!view.hasTouch) {
    box = await center(); await reset(); await p.mouse.move(box.x, box.y); a = await state();
    for (let i = 0; i < 12; i++) { await p.mouse.wheel({ deltaX: 40 }); await sleep(16); }
    await sleep(1100); z = await state(); log('trackpad deltaX ×12 (480px)', a, z);

    box = await center(); await reset(); await p.mouse.move(box.x, box.y); a = await state();
    for (let i = 0; i < 3; i++) { await p.mouse.wheel({ deltaX: 30 }); await sleep(16); }
    await sleep(1100); z = await state(); log('short trackpad swipe (90px)', a, z);

    box = await center(); await reset(); await p.mouse.move(box.x, box.y); a = await state();
    await p.keyboard.down('Shift'); for (let i = 0; i < 4; i++) { await p.mouse.wheel({ deltaY: 100 }); await sleep(16); } await p.keyboard.up('Shift');
    await sleep(1100); z = await state(); log('shift+wheel', a, z);

    box = await center(); await reset(); await p.mouse.move(box.x, box.y); a = await state();
    await p.mouse.wheel({ deltaY: 300 }); await sleep(800); z = await state(); log('vertical wheel (page scrolls)', a, z);

    box = await center(); await reset(); a = await state();
    await p.mouse.move(box.x + 200, box.y); await p.mouse.down();
    for (let i = 1; i <= 12; i++) { await p.mouse.move(box.x + 200 - i * 30, box.y); await sleep(12); }
    const mid = await state(); await p.mouse.up(); await sleep(1100); z = await state();
    log('mouse drag + fling', a, z, `(mid-drag ${mid.left}, selection "${await p.evaluate(() => String(getSelection()))}")`);

    box = await center(); await reset();
    await p.evaluate(() => { window.__clicks = 0; document.getElementById(window.__TRACK).addEventListener('click', () => window.__clicks++); });
    await p.mouse.move(box.x - 400, box.y); await p.mouse.down(); await p.mouse.move(box.x - 520, box.y, { steps: 6 }); await p.mouse.up(); await sleep(900);
    console.log(`${label} clicks delivered after a drag: ${await p.evaluate(() => window.__clicks)}`);
    await p.mouse.click(box.x - 400, box.y); await sleep(200);
    console.log(`${label} clicks delivered by a plain click: ${await p.evaluate(() => window.__clicks)}`);

    box = await center(); await reset(); await p.evaluate(() => document.getElementById(window.__TRACK).focus()); a = await state();
    await p.keyboard.press('ArrowRight'); await sleep(900); z = await state(); log('ArrowRight', a, z);
    a = z; await p.keyboard.press('End'); await sleep(1000); z = await state(); log('End', a, z, `next disabled:${await p.evaluate(() => document.getElementById(window.__TRACK).parentElement.querySelector('.cards__nav--next').disabled)}`);
    a = z; await p.keyboard.press('Home'); await sleep(1000); z = await state(); log('Home', a, z, `prev disabled:${await p.evaluate(() => document.getElementById(window.__TRACK).parentElement.querySelector('.cards__nav--prev').disabled)}`);
  } else {
    const c = await p.target().createCDPSession();
    for (const [name, dist] of [['touch swipe 300px', 300], ['touch swipe 120px', 120]]) {
      box = await center(); await reset(); a = await state();
      const tp = (x) => [{ x, y: box.y, id: 1 }];
      await c.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: tp(box.x + 120) });
      const n = 10;
      for (let i = 1; i <= n; i++) { await c.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: tp(box.x + 120 - (i * dist) / n) }); await sleep(16); }
      await c.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
      await sleep(1400); z = await state(); log(name, a, z);
    }
  }
  await b.close();
}
(async () => {
  for (const t of ['feature-cards', 'touch-cards']) {
    await run({ width: 1512, height: 945 }, `desktop ${t}`, t);
    await run({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }, `phone ${t}`, t);
  }
})();
