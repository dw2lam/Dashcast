// Letterboxed frame renderers for an HTMLCanvasElement or an OffscreenCanvas.
// WebGL: one texture re-uploaded per frame (VideoFrame / ImageBitmap), drawn as a quad
// into the aspect-fit viewport. Canvas 2D is the fallback.

export type Source = VideoFrame | ImageBitmap;
type AnyCanvas = HTMLCanvasElement | OffscreenCanvas;

export interface Renderer {
  kind: 'webgl' | '2d';
  draw(src: Source, w: number, h: number): void;
  /** Resize the backing store; returns true when the last frame could be repainted. */
  resize(w: number, h: number): boolean;
  /** Debug: RGB at canvas pixel [x, y] (top-left origin), read right after a draw. */
  sample(x: number, y: number): number[];
}

/** Aspect-fit rect [x, y, w, h] of a w×h frame centred in a cw×ch box. */
export function fit(cw: number, ch: number, w: number, h: number): number[] {
  const s = Math.min(cw / w, ch / h);
  const dw = Math.round(w * s);
  const dh = Math.round(h * s);
  return [(cw - dw) >> 1, (ch - dh) >> 1, dw, dh];
}

export function createRenderer(c: AnyCanvas, pref: string): Renderer | null {
  if (pref !== '2d') {
    try {
      const r = webgl(c);
      if (r) return r;
    } catch {
      /* fall through */
    }
  }
  try {
    return canvas2d(c);
  } catch {
    return null;
  }
}

const VS = 'attribute vec2 p;varying vec2 v;void main(){v=vec2(p.x*.5+.5,.5-p.y*.5);gl_Position=vec4(p,0.,1.);}';
const FS =
  '#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n' +
  'uniform sampler2D t;varying vec2 v;void main(){gl_FragColor=texture2D(t,v);}';

function webgl(c: AnyCanvas): Renderer | null {
  const g = c.getContext('webgl', {
    alpha: false,
    antialias: false,
    depth: false,
    stencil: false,
    premultipliedAlpha: false,
    preserveDrawingBuffer: false,
  }) as WebGLRenderingContext | null;
  if (!g) return null;
  const prog = g.createProgram()!;
  for (const [type, src] of [
    [g.VERTEX_SHADER, VS],
    [g.FRAGMENT_SHADER, FS],
  ] as [number, string][]) {
    const s = g.createShader(type)!;
    g.shaderSource(s, src);
    g.compileShader(s);
    g.attachShader(prog, s);
  }
  g.bindAttribLocation(prog, 0, 'p');
  g.linkProgram(prog);
  if (!g.getProgramParameter(prog, g.LINK_STATUS)) return null;
  g.useProgram(prog);
  g.bindBuffer(g.ARRAY_BUFFER, g.createBuffer());
  g.bufferData(g.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), g.STATIC_DRAW);
  g.enableVertexAttribArray(0);
  g.vertexAttribPointer(0, 2, g.FLOAT, false, 0, 0);
  g.bindTexture(g.TEXTURE_2D, g.createTexture());
  g.texParameteri(g.TEXTURE_2D, g.TEXTURE_MIN_FILTER, g.LINEAR);
  g.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.LINEAR);
  g.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_S, g.CLAMP_TO_EDGE);
  g.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_T, g.CLAMP_TO_EDGE);
  g.clearColor(0, 0, 0, 1);
  let vw = 0;
  let vh = 0;
  const paint = () => {
    const cw = c.width;
    const ch = c.height;
    g.viewport(0, 0, cw, ch);
    g.clear(g.COLOR_BUFFER_BIT);
    if (!vw) return;
    const r = fit(cw, ch, vw, vh);
    g.viewport(r[0], ch - r[1] - r[3], r[2], r[3]);
    g.drawArrays(g.TRIANGLE_STRIP, 0, 4);
  };
  return {
    kind: 'webgl',
    draw(src, w, h) {
      if (g.isContextLost()) return;
      g.texImage2D(g.TEXTURE_2D, 0, g.RGBA, g.RGBA, g.UNSIGNED_BYTE, src as TexImageSource);
      vw = w;
      vh = h;
      paint();
    },
    resize(w, h) {
      c.width = w;
      c.height = h;
      if (g.isContextLost()) return false;
      paint();
      return vw > 0;
    },
    sample(x, y) {
      const px = new Uint8Array(4);
      g.readPixels(x, c.height - 1 - y, 1, 1, g.RGBA, g.UNSIGNED_BYTE, px);
      return [px[0], px[1], px[2]];
    },
  };
}

function canvas2d(c: AnyCanvas): Renderer {
  const x = c.getContext('2d', { alpha: false }) as CanvasRenderingContext2D | null;
  if (!x) throw new Error('no 2d context');
  let lw = 0;
  let lh = 0;
  const clear = () => {
    x.fillStyle = '#000';
    x.fillRect(0, 0, c.width, c.height);
  };
  return {
    kind: '2d',
    draw(src, w, h) {
      if (w !== lw || h !== lh) {
        clear();
        lw = w;
        lh = h;
      }
      const r = fit(c.width, c.height, w, h);
      x.drawImage(src as CanvasImageSource, r[0], r[1], r[2], r[3]);
    },
    resize(w, h) {
      c.width = w;
      c.height = h;
      clear();
      lw = lh = 0;
      return false;
    },
    sample(x0, y0) {
      const d = x.getImageData(x0, y0, 1, 1).data;
      return [d[0], d[1], d[2]];
    },
  };
}
