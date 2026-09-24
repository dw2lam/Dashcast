#!/usr/bin/env node
// Builds ONE self-contained dist/index.html: CSS + JS inlined, the video Worker and the
// AudioWorklet inlined as strings (loaded via Blob URLs). Target: Chrome 79 (Tesla MCU2).
//   node build.mjs           build once
//   node build.mjs --watch   rebuild on changes in src/
import * as esbuild from 'esbuild';
import { readFileSync, writeFileSync, mkdirSync, watch } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const root = dirname(fileURLToPath(import.meta.url));
const src = (p) => join(root, 'src', p);
const TARGET = 'chrome79';

const jsOpts = {
  bundle: true,
  minify: true,
  write: false,
  format: 'iife',
  target: TARGET,
  legalComments: 'none',
  charset: 'utf8',
  logLevel: 'warning',
};

async function js(entry, define) {
  const r = await esbuild.build({ ...jsOpts, entryPoints: [src(entry)], define });
  return r.outputFiles[0].text.trim();
}

async function build() {
  const t0 = Date.now();
  const worker = await js('video/worker.ts');
  const worklet = await js('audio/worklet.ts');
  const main = await js('main.ts', {
    __WORKER_SRC__: JSON.stringify(worker),
    __WORKLET_SRC__: JSON.stringify(worklet),
  });
  const css = (
    await esbuild.build({
      entryPoints: [src('styles.css')],
      bundle: true,
      minify: true,
      write: false,
      target: TARGET,
      logLevel: 'warning',
    })
  ).outputFiles[0].text.trim();

  const html = readFileSync(src('index.html'), 'utf8')
    .replace(/>\s+</g, '><')
    .replace('<!--CSS-->', () => `<style>${css}</style>`)
    .replace('<!--JS-->', () => `<script>${main.replace(/<\/(script)/gi, '<\\/$1')}</script>`)
    .trim();

  mkdirSync(join(root, 'dist'), { recursive: true });
  writeFileSync(join(root, 'dist', 'index.html'), html + '\n');
  const kb = (n) => (n / 1024).toFixed(1) + ' KB';
  console.log(
    `dist/index.html ${kb(Buffer.byteLength(html))} (gzip ${kb(gzipSync(html).length)}) — ` +
      `main ${kb(main.length - worker.length - worklet.length)}, worker ${kb(worker.length)}, ` +
      `worklet ${kb(worklet.length)}, css ${kb(css.length)} [${Date.now() - t0} ms]`,
  );
}

await build();

if (process.argv.includes('--watch')) {
  let timer = null;
  watch(join(root, 'src'), { recursive: true }, () => {
    clearTimeout(timer);
    timer = setTimeout(() => build().catch((e) => console.error(e.message)), 80);
  });
  console.log('watching src/ …');
}
