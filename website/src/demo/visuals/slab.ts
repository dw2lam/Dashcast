import { PANEL } from '../tesla/tesla';

/** Visible bezel around the active area, panel px (matches the Screen view's slab). */
export const BEZEL = 30;

export interface SlabFit {
  x: number;
  y: number;
  k: number;
  w: number;
  h: number;
}

/** Fits the straight-on slab (panel + bezel) into a box, centred, leaving `pad` px all round. */
export function fitSlab(W: number, H: number, pad: number): SlabFit {
  const k = Math.min((W - 2 * pad) / (PANEL.w + 2 * BEZEL), (H - 2 * pad) / (PANEL.h + 2 * BEZEL));
  const w = PANEL.w * k;
  const h = PANEL.h * k;
  return { x: (W - w) / 2, y: (H - h) / 2, k, w, h };
}
