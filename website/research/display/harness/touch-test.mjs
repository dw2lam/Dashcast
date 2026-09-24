import puppeteer from 'puppeteer-core';
const browser = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio', '--autoplay-policy=no-user-gesture-required'] });
const page = await browser.newPage();
await page.setViewport({ width: 1512, height: 945 });
const logs = [];
page.on('pageerror', (e) => logs.push('pageerror ' + e.message));
await page.goto('http://127.0.0.1:5184/research/display/harness/index.html?only=demo', { waitUntil: 'networkidle0' });
await page.evaluate(() => window.scrollTo(0, document.querySelector('.dm-demo-stage').offsetTop - 40));
await new Promise((r) => setTimeout(r, 1200));
const center = (sel) => page.evaluate((sel) => { const r = document.querySelector(sel).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; }, sel);
const state = () => page.evaluate(() => ({
  safari: document.querySelector('.dm-mw-safari').style.transform,
  playing: document.querySelector('.dm-mw-player').classList.contains('dm-playing'),
  tap: document.querySelector('.dm-dcc-tap').className,
  pill: document.querySelector('.dm-dcc-pill').className,
  stats: [...document.querySelectorAll('.dm-dcc-panel dd')].map((d) => d.textContent).slice(0, 9).join(' | '),
}));
console.log('before', JSON.stringify(await state()));
// A first tap anywhere on the glass hands the screen over (desktop live).
const [sx, sy] = await center('.dm-stg-glass .dm-tsl');
await page.mouse.click(sx, sy);
await new Promise((r) => setTimeout(r, 400));
console.log('after tap', JSON.stringify(await state()));
// Drag Safari by its toolbar.
const [bx, by] = await center('.dm-sf-url');
await page.mouse.move(bx + 60, by);
await page.mouse.down();
for (let i = 1; i <= 10; i++) { await page.mouse.move(bx + 60 + i * 8, by + i * 4); await new Promise((r) => setTimeout(r, 16)); }
await page.mouse.up();
await new Promise((r) => setTimeout(r, 300));
console.log('after drag', JSON.stringify(await state()));
// Wheel over the article.
const [ax, ay] = await center('.dm-sf-view');
await page.mouse.move(ax, ay);
await page.mouse.wheel({ deltaY: 240 });
await new Promise((r) => setTimeout(r, 300));
console.log('page scroll', await page.evaluate(() => [document.querySelector('.dm-sf-page').style.transform, window.scrollY]));
// Tap the film.
const [vx, vy] = await center('.dm-mw-player');
await page.mouse.click(vx, vy);
await new Promise((r) => setTimeout(r, 1800));
console.log('after film tap', JSON.stringify(await state()));
// Controls.
await page.evaluate(() => [...document.querySelectorAll('.dm-seg button')].find((b) => b.textContent.startsWith('MCU3')).click());
await new Promise((r) => setTimeout(r, 1200));
console.log('mcu3', JSON.stringify(await state()), await page.evaluate(() => document.querySelector('.dm-tsl').dataset.tier));
console.log(logs.join('\n'));
await browser.close();
