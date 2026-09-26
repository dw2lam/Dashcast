// node --experimental-strip-types --test test/  (npm test)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { nextHost, HOST_MESSAGES, tipWanted, dismissTip, TIP_KEY } from '../src/host.ts';
import type { HostState } from '../src/host.ts';

test('host messages switch the pause on and off', () => {
  let s: HostState = 'active';
  s = nextHost(s, { k: 'host', state: 'locked' });
  assert.equal(s, 'locked');
  s = nextHost(s, { k: 'host', state: 'displayAsleep' });
  assert.equal(s, 'displayAsleep');
  s = nextHost(s, { k: 'host', state: 'active' });
  assert.equal(s, 'active');
});

test('unknown states are ignored', () => {
  assert.equal(nextHost('locked', { k: 'host', state: 'hibernating' }), 'locked');
  assert.equal(nextHost('active', { k: 'host', state: 42 }), 'active');
});

test('a new stream clears any pause', () => {
  for (const s of ['locked', 'displayAsleep', 'sleeping'] as HostState[]) {
    assert.equal(nextHost(s, { k: 'stream' }), 'active');
  }
});

test('the sleep message outlives the socket; other pauses give way to reconnecting', () => {
  assert.equal(nextHost('sleeping', { k: 'lost' }), 'sleeping');
  assert.equal(nextHost('locked', { k: 'lost' }), 'active');
  assert.equal(nextHost('displayAsleep', { k: 'lost' }), 'active');
  assert.equal(nextHost('active', { k: 'lost' }), 'active');
});

test('copy', () => {
  assert.equal(HOST_MESSAGES.locked.title, 'Your Mac is locked');
  assert.equal(HOST_MESSAGES.locked.body, 'Unlock it to keep streaming.');
  assert.equal(HOST_MESSAGES.sleeping.title, 'Your Mac went to sleep');
  assert.equal(HOST_MESSAGES.sleeping.body, 'Wake it to reconnect.');
});

test('bookmark tip: once dismissed, never again; broken storage still works', () => {
  const data = new Map<string, string>();
  const store = { getItem: (k: string) => data.get(k) ?? null, setItem: (k: string, v: string) => void data.set(k, v) };
  assert.equal(tipWanted(store), true);
  dismissTip(store);
  assert.equal(data.get(TIP_KEY), 'dismissed');
  assert.equal(tipWanted(store), false);

  const throwing = { getItem: () => { throw new Error('SecurityError'); }, setItem: () => { throw new Error('QuotaExceeded'); } };
  assert.equal(tipWanted(throwing), true);
  assert.doesNotThrow(() => dismissTip(throwing));
  assert.equal(tipWanted(null), true);
});
