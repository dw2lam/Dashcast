// AudioWorkletProcessor: plays PCM packets posted by the main thread at the absolute
// context frame they were scheduled for. Loaded from a Blob URL (see build.mjs).
import { Ring } from './ring';

declare const currentFrame: number;
declare class AudioWorkletProcessor {
  readonly port: MessagePort;
}
declare function registerProcessor(name: string, ctor: unknown): void;

class DashcastPcm extends AudioWorkletProcessor {
  private ring = new Ring();

  constructor() {
    super();
    this.port.onmessage = (e: MessageEvent) => {
      const d = e.data;
      if (d.at == null) this.ring.reset();
      else this.ring.write(d.at, d.count, new Int16Array(d.buf, 16, d.n * 2), d.n);
    };
  }

  process(_in: Float32Array[][], out: Float32Array[][]): boolean {
    const o = out[0];
    const l = o[0];
    this.ring.read(currentFrame, l, o[1] || l, l.length);
    return true;
  }
}

registerProcessor('dashcast-pcm', DashcastPcm);
