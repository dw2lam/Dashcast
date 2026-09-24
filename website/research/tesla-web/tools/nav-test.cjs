const puppeteer = require('../../../node_modules/puppeteer-core');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const IDS = ['demo', 'app', 'connect', 'tech', 'faq', 'download'];
async function settle(p) {
  let last = -1, same = 0;
  for (let i = 0; i < 80; i++) { const y = await p.evaluate(() => scrollY); if (y === last) { if (++same >= 5) return; } else same = 0; last = y; await sleep(60); }
}
async function run(view, label, ua) {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  const p = await b.newPage();
  if (ua) await p.setUserAgent(ua);
  await p.setViewport(view);
  await p.goto('http://127.0.0.1:5191/', { waitUntil: 'networkidle2' });
  await p.evaluate(() => document.fonts.ready); await sleep(1500);
  const phone = view.width < 900;
  for (const id of IDS) {
    await p.evaluate(() => { window.__pills = []; window.__t = setInterval(() => { const a = document.querySelector('.nav__item.is-active'); window.__pills.push(a ? a.textContent : '-'); }, 40); });
    if (phone) {
      await p.click('.nav__menu-btn'); await sleep(600);
      await p.evaluate((id) => [...document.querySelectorAll('.menu__item')].find((a) => a.getAttribute('href') === '#' + id).click(), id);
    } else {
      await p.evaluate((id) => document.querySelector(`.nav__item[data-id="${id}"]`).click(), id);
    }
    await sleep(200); await settle(p);
    const r = await p.evaluate((id) => {
      clearInterval(window.__t);
      const el = document.getElementById(id);
      const h = el.querySelector('h1, h2');
      const pills = [...new Set(window.__pills.filter((x) => x !== '-'))];
      return { secTop: Math.round(el.getBoundingClientRect().top), headTop: h ? Math.round(h.getBoundingClientRect().top) : null, hash: location.hash, focus: document.activeElement === h, pills: pills.join('>'), menuOpen: document.querySelector('.menu').classList.contains('is-open') };
    }, id);
    console.log(`${label} #${id}`.padEnd(22), `section top ${r.secTop}px (target 56±4) ${Math.abs(r.secTop - 56) <= 4 ? 'OK' : 'OFF'}`.padEnd(40), `heading ${r.headTop}px`.padEnd(14), `hash ${r.hash}`.padEnd(18), `focus:${r.focus}`, `pill:[${r.pills}]`, phone ? `menuOpen:${r.menuOpen}` : '');
  }
  // CTA + in-page anchors from the top
  await p.evaluate(() => window.scrollTo(0, 0)); await sleep(300);
  await p.evaluate(() => document.querySelector('.hero__ctas a[href^="#"]').click()); await sleep(200); await settle(p);
  const cta = await p.evaluate(() => { const a = document.querySelector('.hero__ctas a[href^="#"]'); const id = a.getAttribute('href').slice(1); return id + ' ' + Math.round(document.getElementById(id).getBoundingClientRect().top); });
  console.log(`${label} hero CTA →`, cta);
  await b.close();
}
async function deep(view, label, hash) {
  const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio'] });
  const p = await b.newPage(); await p.setViewport(view);
  await p.goto('http://127.0.0.1:5191/' + hash, { waitUntil: 'networkidle2' }); await sleep(3200);
  console.log(`${label} deep link ${hash}`.padEnd(30), await p.evaluate((id) => Math.round(document.getElementById(id).getBoundingClientRect().top) + 'px', hash.slice(1)));
  await b.close();
}
(async () => {
  const UA = 'Mozilla/5.0 (X11; GNU/Linux) AppleWebKit/537.36 (KHTML, like Gecko) Chromium/79.0.3945.130 Chrome/79.0.3945.130 Safari/537.36 Tesla/2024.26.7';
  await run({ width: 1512, height: 945 }, 'd1512');
  await run({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }, 'p390');
  await run({ width: 1255, height: 784, deviceScaleFactor: 1.53 }, 'car1255', UA);
  for (const h of ['#faq', '#connect', '#app', '#download']) await deep({ width: 1512, height: 945 }, 'd1512', h);
  await deep({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }, 'p390', '#faq');
})();
