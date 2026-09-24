import type { Quad } from './geometry';

const base = '/demo/';

/**
 * "Model Y cabin from the back seat" by I'M ZION (unsplash.com/photos/u4FO_unYC8I, Unsplash License),
 * cropped to y 360–4000 of the 5512×4410 original. `quad` is the display's active area (TL, TR, BR, BL)
 * in cropped-photo px: edge-fitted on the lit UI (0.1 px rms per side), extended through the black
 * dock by the panel's own geometry. research/display/NOTES.md has the method and checks.
 */
export const PHOTO = {
  width: 5512,
  height: 3640,
  src: { 1600: base + 'cabin-1600.webp', 2560: base + 'cabin-2560.webp', 3840: base + 'cabin-3840.webp', 5504: base + 'cabin-5504.webp' } as Record<number, string>,
  quad: [
    [2117.34, 1377.15],
    [3447.24, 1375.77],
    [3455.69, 2208.08],
    [2112.84, 2206.69],
  ] as Quad,
  focus: { x: 2112, y: 1375, w: 1343, h: 833 },
};
