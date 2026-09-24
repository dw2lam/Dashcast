// Silent end-to-end probe: headless Chrome (Tesla-like viewport) loads a Dashcast URL and
// prints window.__dashcast.state() samples. Usage: node cdp-probe.mjs <url> <seconds> [evalAfter]
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import WebSocket from 'ws';

const [url, secs = '8', evalAfter] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'dc-chrome-'));
const port = 9300 + Math.floor(Math.random() * 500);
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  '--mute-audio', '--autoplay-policy=no-user-gesture-required', '--no-first-run', 'about:blank',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === 'page'); } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.on('open', r));
let id = 0; const pending = new Map();
ws.on('message', (m) => { const d = JSON.parse(m); if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
  if (d.method === 'Runtime.consoleAPICalled' && d.params.type === 'error') console.log('console.error', JSON.stringify(d.params.args.map((a) => a.value ?? a.description)));
  if (d.method === 'Runtime.exceptionThrown') console.log('exception', d.params.exceptionDetails.exception?.description ?? d.params.exceptionDetails.text); });
const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true })).result?.result?.value;

await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride', { width: 1255, height: 784, deviceScaleFactor: 1.53, mobile: false });
await send('Page.navigate', { url });
// A trusted click satisfies the autoplay gesture ("Tap to start") so audio runs (Chrome is --mute-audio).
setTimeout(async () => {
  for (const type of ['mousePressed', 'mouseReleased'])
    await send('Input.dispatchMouseEvent', { type, x: 20, y: 20, button: 'left', clickCount: 1 });
}, 2500);
const end = Date.now() + Number(secs) * 1000;
let evaluated = false;
while (Date.now() < end) {
  await sleep(2000);
  if (evalAfter && !evaluated && Date.now() > end - Number(secs) * 500) { console.log('eval →', JSON.stringify(await evaluate(evalAfter))); evaluated = true; }
  const s = await evaluate('window.__dashcast && JSON.stringify((({status,transport,tier,codec,mode,fps,decodeMs,latencyMs,dropped,framesPresented,path,frame,rttMs,audio,rtc})=>({status,transport,tier,codec,mode,fps,decodeMs,latencyMs,dropped,framesPresented,path,frame,rttMs,audio:{kind:audio.kind,state:audio.state,bufferMs:audio.bufferMs,latencyMs:audio.latencyMs,targetMs:audio.targetMs,underruns:audio.underruns},rtc:{state:rtc.state,video:rtc.video}}))(window.__dashcast.state()))');
  console.log(s);
}
ws.close(); chrome.kill('SIGKILL'); await sleep(300); rmSync(profile, { recursive: true, force: true });
process.exit(0);
