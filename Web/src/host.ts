// The Mac's state (PROTOCOL.md `host`) and the calm full-screen message the car shows for it.
export type HostState = 'active' | 'locked' | 'displayAsleep' | 'sleeping';
export type HostEvent = { k: 'host'; state: unknown } | { k: 'stream' } | { k: 'lost' };

export interface HostMessage {
  title: string;
  body: string;
  icon: 'lock' | 'display' | 'moon';
}

export const HOST_MESSAGES: Record<Exclude<HostState, 'active'>, HostMessage> = {
  locked: { title: 'Your Mac is locked', body: 'Unlock it to keep streaming.', icon: 'lock' },
  displayAsleep: { title: 'Your Mac’s display is asleep', body: 'Wake it to keep streaming.', icon: 'display' },
  sleeping: { title: 'Your Mac went to sleep', body: 'Wake it to reconnect.', icon: 'moon' },
};

const STATES: HostState[] = ['active', 'locked', 'displayAsleep', 'sleeping'];

/**
 * What to show after an event. A new stream (config) or `active` clears the pause. When the
 * socket dies after `sleeping` the sleep message stays (that's why it died); any other pause
 * gives way to the usual reconnecting status.
 */
export function nextHost(current: HostState, e: HostEvent): HostState {
  switch (e.k) {
    case 'host':
      return STATES.indexOf(e.state as HostState) >= 0 ? (e.state as HostState) : current;
    case 'stream':
      return 'active';
    case 'lost':
      return current === 'sleeping' ? 'sleeping' : 'active';
  }
}

// ---- one-time bookmark tip ------------------------------------------------------------

export const TIP_KEY = 'dashcast.bookmarkTip';
type Store = Pick<Storage, 'getItem' | 'setItem'>;

/** Show the tip unless it was dismissed on this car (storage can be missing or throw). */
export function tipWanted(store: Store | null): boolean {
  try {
    return !store || store.getItem(TIP_KEY) !== 'dismissed';
  } catch {
    return true;
  }
}

export function dismissTip(store: Store | null) {
  try {
    if (store) store.setItem(TIP_KEY, 'dismissed');
  } catch {
    /* private mode: it just shows again next time */
  }
}
