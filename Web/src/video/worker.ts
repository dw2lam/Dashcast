// Video Worker: owns the OffscreenCanvas, the VideoDecoder / JPEG decode and presentation,
// so the car's weak main thread only shuffles bytes.
//
// The same script doubles as the main-thread fallback: evaluated in a window it just
// exposes the Pipeline class (saves shipping the pipeline twice).
import { Pipeline } from './pipeline';

const g = self as any;

if (typeof document === 'undefined') {
  let p: Pipeline | null = null;
  g.onmessage = (e: MessageEvent) => {
    const m = e.data;
    if (m.k === 'init') {
      // Align clocks: main-thread performance.now() = ours + delta.
      const to = performance.timeOrigin;
      const delta = to && m.t0 ? to - m.t0 : m.now - performance.now();
      p = new Pipeline(m.canvas, m.r || '', delta, (x) => g.postMessage(x));
    } else if (p) p.handle(m);
  };
} else g.__dashcastPipeline = Pipeline;
