// Frame-addressed stereo ring buffer shared by the AudioWorklet and the ScriptProcessor
// fallback. Writes land at absolute AudioContext frame numbers; reads for frames outside
// the valid [s, e) window produce silence (underrun / gap).
const N = 1 << 17; // ~2.7 s at 48 kHz
const M = N - 1;
const FADE = 64;

export class Ring {
  private L = new Float32Array(N);
  private R = new Float32Array(N);
  private s = 0;
  private e = 0;

  reset(): void {
    this.s = this.e = 0;
  }

  /** Write `n` s16le stereo frames resampled to `count` output frames at frame `at`. */
  write(at: number, count: number, pcm: Int16Array, n: number): void {
    const fresh = at !== this.e;
    if (fresh) this.s = at; // discontinuity: new region (gap filled with silence)
    const L = this.L;
    const R = this.R;
    const step = n / count;
    let idx = at % N;
    for (let i = 0; i < count; i++) {
      let l: number;
      let r: number;
      if (step === 1) {
        l = pcm[2 * i] / 32768;
        r = pcm[2 * i + 1] / 32768;
      } else {
        const x = i * step;
        const j = x | 0;
        const k = j + 1 < n ? j + 1 : j;
        const f = x - j;
        l = (pcm[2 * j] + (pcm[2 * k] - pcm[2 * j]) * f) / 32768;
        r = (pcm[2 * j + 1] + (pcm[2 * k + 1] - pcm[2 * j + 1]) * f) / 32768;
      }
      if (fresh && i < FADE) {
        l *= i / FADE;
        r *= i / FADE;
      }
      L[idx] = l;
      R[idx] = r;
      idx = (idx + 1) & M;
    }
    this.e = at + count;
    if (this.e - this.s > N) this.s = this.e - N;
  }

  read(f0: number, l: Float32Array, r: Float32Array, len: number): void {
    const s = this.s;
    const e = this.e;
    let idx = f0 % N;
    for (let i = 0; i < len; i++) {
      const f = f0 + i;
      if (f >= s && f < e) {
        l[i] = this.L[idx];
        r[i] = this.R[idx];
      } else {
        l[i] = 0;
        r[i] = 0;
      }
      idx = (idx + 1) & M;
    }
  }
}
