import puppeteer from 'puppeteer-core';
const [out] = process.argv.slice(2);
const browser = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true, args: ['--mute-audio', '--hide-scrollbars'] });
const page = await browser.newPage();
await page.setViewport({ width: +(process.env.W || 1280), height: +(process.env.H || 720), deviceScaleFactor: +(process.env.DPR || 1) });
const logs = [];
page.on('pageerror', (e) => logs.push('pageerror ' + e.message));
await page.goto((process.argv[3] || 'http://127.0.0.1:5184/research/display/harness/index.html?capture=1') + '', { waitUntil: 'networkidle0' });
await page.waitForFunction('window.__dashcastCapture');
await page.evaluate('window.__dashcastCapture.ready');
for (const t of [0, 1.2, 3.6, 5.8, 8.2, 9.967]) {
  const t0 = Date.now();
  await page.evaluate((t) => window.__dashcastCapture.seek(t), t);
  await page.screenshot({ path: `${out}/cap-${t}.png` });
  console.log('seek', t, Date.now() - t0, 'ms');
}
console.log(logs.join('\n'));
await browser.close();
