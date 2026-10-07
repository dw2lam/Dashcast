// node --experimental-strip-types --test test/  (npm test)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ring } from '../src/audio/ring.ts';

/** `frames` stereo s16 frames of one value. */
const pcm = (frames: number, v: number) => new Int16Array(frames * 2).fill(v);

function read(r: Ring, f0: number, len: number) {
  const l = new Float32Array(len);
  const rr = new Float32Array(len);
  r.read(f0, l, rr, len);
  return l;
}

test('contiguous writes play back in order; outside the written window is silence', () => {
  const r = new Ring();
  r.write(1000, 480, pcm(480, 16384), 480);
  r.write(1480, 480, pcm(480, 8192), 480);
  const l = read(r, 900, 1200);
  assert.equal(l[50], 0); // before the region
  assert.equal(l[100 + 64], 0.5); // first packet (after the 64-frame fade-in)
  assert.equal(l[100 + 480 + 10], 0.25); // second packet: contiguous, no fade
  assert.equal(l[100 + 960 + 1], 0); // after the region
});

test('a forward re-anchor keeps the audio already buffered and leaves only the gap silent', () => {
  const r = new Ring();
  r.write(0, 480, pcm(480, 16384), 480); // buffered, not yet played
  r.write(1000, 480, pcm(480, 8192), 480); // target moved later (e.g. interactive → cinema)
  const l = read(r, 0, 1480);
  assert.equal(l[200], 0.5, 'buffered audio still plays');
  assert.equal(l[479], 0.5);
  assert.equal(l[480], 0);
  assert.equal(l[999], 0, 'gap is silence');
  assert.equal(l[1000 + 100], 0.25, 'new audio after the gap');
});

test('a backward re-anchor plays the buffered audio up to the new write', () => {
  const r = new Ring();
  r.write(0, 960, pcm(960, 16384), 960);
  r.write(600, 480, pcm(480, 8192), 480); // target moved earlier (cinema → interactive)
  const l = read(r, 0, 1200);
  assert.equal(l[300], 0.5);
  assert.equal(l[600 + 100], 0.25);
  assert.equal(l[1080 + 10], 0, 'old tail past the new end is gone');
});

test('a gap longer than the ring starts a fresh region', () => {
  const r = new Ring();
  r.write(0, 480, pcm(480, 16384), 480);
  const far = 1 << 18;
  r.write(far, 480, pcm(480, 8192), 480);
  assert.equal(read(r, 200, 1)[0], 0);
  assert.equal(read(r, far + 100, 1)[0], 0.25);
});

test('resampling stretches n source frames over count output frames', () => {
  const r = new Ring();
  const src = new Int16Array(480 * 2);
  for (let i = 0; i < 480; i++) src[2 * i] = src[2 * i + 1] = i * 32;
  r.write(0, 482, src, 480); // two frames longer (drift steering)
  const l = read(r, 0, 482);
  assert.ok(Math.abs(l[481] - (479 * 32) / 32768) < 1e-6, 'last output frame is the last input frame');
  for (let i = 65; i < 482; i++) assert.ok(l[i] >= l[i - 1], 'monotonic ramp stays monotonic');
});
