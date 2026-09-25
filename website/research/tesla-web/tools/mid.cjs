// Mid-animation frames: node mid.cjs <w> <h> <label>. Clicks a control, then shoots partway through its motion.
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
  const at = async (sel, off) => { await p.evaluate((s, o) => { const el = document.querySelector(s); window.scrollTo(0, el.getBoundingClientRect().top + scrollY - 56 + o); }, sel, off); await sleep(1600); };
  const shot = (n) => p.screenshot({ path: path.join(__dirname, 'out', `mid-${label}-${n}.png`) });
  const click = (sel) => p.evaluate((s) => document.querySelector(s).click(), sel);

  await at('#features', -40);
  if (+W >= 900) { await click('.fcards__arrow--next'); } else { await click('.fcards__dot:nth-child(2)'); }
  await sleep(220); await shot('features');

  await at('#demo', +W < 600 ? 300 : 200);
  await p.evaluate(() => [...document.querySelectorAll('#demo .ui-seg__opt')].find((b) => b.textContent === 'Mirror').click());
  await sleep(300); await shot('demo');

  await at('#app', +W < 600 ? 250 : 150);
  await p.evaluate(() => [...document.querySelectorAll('#app .ui-seg__opt')].find((b) => b.textContent === 'Guide').click());
  await sleep(350); await shot('app');

  await at('#office', 0);
  await p.evaluate(() => [...document.querySelectorAll('.office__step')][2].click());
  await sleep(450); await shot('office');
  await b.close();
})();
