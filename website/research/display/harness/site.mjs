import puppeteer from 'puppeteer-core';
const [out, w, h, dpr = '1', ...scrolls] = process.argv.slice(2);
const browser = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio', '--hide-scrollbars'] });
const page = await browser.newPage();
const mobile = +w < 700;
await page.setViewport({ width: +w, height: +h, deviceScaleFactor: +dpr, isMobile: mobile, hasTouch: mobile });
const logs = [];
page.on('pageerror', (e) => logs.push('pageerror ' + e.message));
page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') logs.push(m.type() + ' ' + m.text()); });
await page.goto('http://127.0.0.1:5184/', { waitUntil: 'networkidle0' });
await new Promise((r) => setTimeout(r, 1500));
for (const s of scrolls.length ? scrolls : ['0']) {
  const [y, t] = s.split('@');
  await page.evaluate((y) => window.scrollTo(0, y === 'demo' ? document.getElementById('demo').offsetTop : +y), y);
  await new Promise((r) => setTimeout(r, 900));
  if (t) await page.evaluate(async (t) => { const g = (await import('/node_modules/.vite/deps/gsap.js')).default; }, t).catch(() => {});
  await page.screenshot({ path: `${out}-${w}x${h}-${y}.png` });
}
const m = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth, demoTop: document.getElementById('demo')?.offsetTop }));
console.log(JSON.stringify(m));
console.log(logs.filter((l) => !l.includes('favicon')).join('\n'));
await browser.close();
