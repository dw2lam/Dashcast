// Server-clock estimate from ping/pong: offset = serverTime - (send+recv)/2, taking the
// sample with the lowest RTT of the last 20. serverUs = performance.now()*1000 + offsetUs.
export class Clock {
  offsetUs = 0;
  rtt = NaN;
  synced = false;
  private s: number[] = []; // flat [rtt, offset, rtt, offset, ...]

  reset(): void {
    this.s.length = 0;
    this.synced = false;
    this.rtt = NaN;
  }

  /** Rough offset from config.serverTime until the first pong lands. */
  seed(serverUs: number): void {
    if (!this.synced && serverUs > 0) this.offsetUs = serverUs - performance.now() * 1000;
  }

  /** Returns true when the offset moved enough to be worth broadcasting. */
  pong(sentMs: number, serverUs: number): boolean {
    const now = performance.now();
    const rtt = now - sentMs;
    if (!(rtt >= 0) || rtt > 10000 || !(serverUs > 0)) return false;
    this.rtt = rtt;
    this.s.push(rtt, serverUs - (sentMs + now) * 500);
    if (this.s.length > 40) this.s.splice(0, 2);
    let best = 0;
    for (let i = 2; i < this.s.length; i += 2) if (this.s[i] < this.s[best]) best = i;
    const off = this.s[best + 1];
    const changed = !this.synced || Math.abs(off - this.offsetUs) > 250;
    this.offsetUs = off;
    this.synced = true;
    return changed;
  }

  minRtt(): number {
    let m = NaN;
    for (let i = 0; i < this.s.length; i += 2) if (!(this.s[i] >= m)) m = this.s[i];
    return m;
  }

  /** Current server time in µs. */
  now(): number {
    return performance.now() * 1000 + this.offsetUs;
  }
}
