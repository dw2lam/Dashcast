export type Pt = [number, number];
export type Quad = [Pt, Pt, Pt, Pt];

/**
 * CSS matrix3d that maps a w×h box (origin top-left, transform-origin 0 0) onto `quad`
 * (TL, TR, BR, BL). Projective square→quad mapping (Heckbert), columns scaled by the box size.
 */
export function quadMatrix(w: number, h: number, quad: Quad): string {
  const [[x0, y0], [x1, y1], [x2, y2], [x3, y3]] = quad;
  const dx1 = x1 - x2;
  const dx2 = x3 - x2;
  const dx3 = x0 - x1 + x2 - x3;
  const dy1 = y1 - y2;
  const dy2 = y3 - y2;
  const dy3 = y0 - y1 + y2 - y3;
  let g = 0;
  let hh = 0;
  if (Math.abs(dx3) > 1e-9 || Math.abs(dy3) > 1e-9) {
    const den = dx1 * dy2 - dx2 * dy1;
    g = (dx3 * dy2 - dx2 * dy3) / den;
    hh = (dx1 * dy3 - dx3 * dy1) / den;
  }
  const a = x1 - x0 + g * x1;
  const b = x3 - x0 + hh * x3;
  const d = y1 - y0 + g * y1;
  const e = y3 - y0 + hh * y3;
  const m = [a / w, d / w, 0, g / w, b / h, e / h, 0, hh / h, 0, 0, 1, 0, x0, y0, 0, 1];
  return 'matrix3d(' + m.map((v) => +v.toPrecision(12)).join(',') + ')';
}

/** Where a photo is drawn inside a container: scale and top-left offset, in container px. */
export interface Placement {
  s: number;
  x: number;
  y: number;
  w: number;
  h: number;
}

/**
 * Cover-fit a photo into cw×ch, zoomed so the focus rect (the screen, photo px) is `targetW` px wide
 * when that is bigger than the cover fit, with the focus centre placed at `bias` (fractions of the
 * container) as far as the photo still covers the container.
 */
export function placePhoto(
  cw: number,
  ch: number,
  pw: number,
  ph: number,
  focus: { x: number; y: number; w: number; h: number },
  targetW: number,
  bias: { x: number; y: number },
): Placement {
  const cover = Math.max(cw / pw, ch / ph);
  const s = Math.max(cover, Math.min(targetW / focus.w, cover * 4));
  const w = pw * s;
  const h = ph * s;
  const fx = (focus.x + focus.w / 2) * s;
  const fy = (focus.y + focus.h / 2) * s;
  const x = clamp(cw * bias.x - fx, cw - w, 0);
  const y = clamp(ch * bias.y - fy, ch - h, 0);
  return { s, x, y, w, h };
}

export const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

export function mapQuad(q: Quad, p: Placement): Quad {
  return q.map(([x, y]) => [p.x + x * p.s, p.y + y * p.s] as Pt) as Quad;
}

/** Point on a quad at normalised (u, v), by the same projective mapping the matrix uses. */
export function quadPoint(q: Quad, u: number, v: number): Pt {
  const [[x0, y0], [x1, y1], [x2, y2], [x3, y3]] = q;
  const dx1 = x1 - x2;
  const dx2 = x3 - x2;
  const dx3 = x0 - x1 + x2 - x3;
  const dy1 = y1 - y2;
  const dy2 = y3 - y2;
  const dy3 = y0 - y1 + y2 - y3;
  let g = 0;
  let hh = 0;
  if (Math.abs(dx3) > 1e-9 || Math.abs(dy3) > 1e-9) {
    const den = dx1 * dy2 - dx2 * dy1;
    g = (dx3 * dy2 - dx2 * dy3) / den;
    hh = (dx1 * dy3 - dx3 * dy1) / den;
  }
  const a = x1 - x0 + g * x1;
  const b = x3 - x0 + hh * x3;
  const d = y1 - y0 + g * y1;
  const e = y3 - y0 + hh * y3;
  const W = g * u + hh * v + 1;
  return [(a * u + b * v + x0) / W, (d * u + e * v + y0) / W];
}

/** Inverse of quadPoint: container px → normalised (u, v) on the quad (for taps on the photo). */
export function quadUV(q: Quad, x: number, y: number): Pt {
  let u = 0.5;
  let v = 0.5;
  for (let i = 0; i < 12; i++) {
    const [px, py] = quadPoint(q, u, v);
    const e = 1e-4;
    const [ux, uy] = quadPoint(q, u + e, v);
    const [vx, vy] = quadPoint(q, u, v + e);
    const j11 = (ux - px) / e;
    const j21 = (uy - py) / e;
    const j12 = (vx - px) / e;
    const j22 = (vy - py) / e;
    const det = j11 * j22 - j12 * j21;
    const rx = x - px;
    const ry = y - py;
    u += (j22 * rx - j12 * ry) / det;
    v += (-j21 * rx + j11 * ry) / det;
  }
  return [u, v];
}
