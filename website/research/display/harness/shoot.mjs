// Headless check of the demo harness: node research/display/harness/shoot.mjs <out-prefix> [w h] [query] [seek-s...]
// Seeks the story timeline(s) to each time, forces GSAP to settle, screenshots and dumps metrics.
import puppeteer from 'puppeteer-core';

const [out = '/tmp/demo', w = '1512', h = '945', query = '', ...times] = process.argv.slice(2);
const browser = await puppeteer.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true,
  args: ['--mute-audio', '--autoplay-policy=no-user-gesture-required', '--hide-scrollbars'],
});
const page = await browser.newPage();
const mobile = Number(w) < 700;
await page.setViewport({ width: Number(w), height: Number(h), deviceScaleFactor: Number(process.env.DPR || (mobile ? 3 : 1)), isMobile: mobile, hasTouch: mobile });
const logs = [];
if (process.env.RM) await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }]);
page.on('console', (m) => logs.push(m.type() + ': ' + m.text()));
page.on('pageerror', (e) => logs.push('pageerror: ' + e.message));
page.on('response', (r) => { if (r.status() >= 400) logs.push('HTTP ' + r.status() + ' ' + r.url()); });
await page.goto('http://127.0.0.1:5184/research/display/harness/index.html' + (query ? '?' + query : ''), { waitUntil: 'networkidle0' });
await new Promise((r) => setTimeout(r, 800));
const list = times.length ? times : ['0'];
for (const t of list) {
  if (t.startsWith('scroll:')) {
    await page.evaluate((y) => window.scrollTo(0, Number(y)), t.slice(7));
    await new Promise((r) => setTimeout(r, 700));
    continue;
  }
  if (t.startsWith('eval:')) {
    console.log('eval', JSON.stringify(await page.evaluate(t.slice(5))));
    await new Promise((r) => setTimeout(r, 400));
    continue;
  }
  await page.evaluate(async (sec) => {
    const g = (await window.__gsap).default;
    const tls = g.globalTimeline.getChildren(false, false, true);
    for (const tl of tls) if (tl.duration() > 20) { tl.pause(); tl.time(Number(sec), false); }
    g.globalTimeline.getChildren(false, true, false).forEach((tw) => { if (tw.duration() < 5) tw.progress(1); });
  }, t);
  await new Promise((r) => setTimeout(r, 500));
  const file = `${out}-${w}x${h}-t${t}.png`;
  await page.screenshot({ path: file });
  console.log('shot', file);
}
console.log(logs.join('\n'));
await browser.close();
