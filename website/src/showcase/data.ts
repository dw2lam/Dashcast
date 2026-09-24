/*
 * The #app showcase: real window captures of the Mac app (scripts/shots/capture.sh → process.py),
 * staged on a small "desktop". Every capture shares one geometry: the window body plus a transparent
 * shadow margin of 56 pt left/right, 38 pt above and 74 pt below, so an image is (w + 112) × (h + 112) pt.
 */

export type Look = 'light' | 'dark';
export type Layer = 'main' | 'panel' | 'guide' | 'settings';
export type LayoutName = 'wide' | 'tall';

export const PAD = { left: 56, top: 38, extra: 112 };

/** Window body sizes in points, and the image variants each layer can show. */
export const WINDOWS: Record<Layer, { w: number; h: number; variants: { id: string; file: string; h?: number }[] }> = {
  main: {
    w: 460,
    h: 580,
    variants: [
      { id: 'waiting', file: 'main-waiting' },
      { id: 'extend', file: 'main-casting-extend' },
      { id: 'mirror', file: 'main-casting-mirror' },
      { id: 'behind', file: 'main-casting-extend-inactive' },
      { id: 'setup-1', file: 'setup-1' },
      { id: 'setup-2', file: 'setup-2' },
      { id: 'setup-3', file: 'setup-3' },
    ],
  },
  panel: { w: 300, h: 372, variants: [{ id: 'casting', file: 'menu-casting' }] },
  guide: { w: 580, h: 692, variants: [{ id: 'guide', file: 'guide' }] },
  settings: {
    w: 520,
    h: 622,
    variants: [
      { id: 'general', file: 'settings-general', h: 622 },
      { id: 'display', file: 'settings-display', h: 387 },
      { id: 'network', file: 'settings-network', h: 648 },
      { id: 'advanced', file: 'settings-advanced', h: 607 },
    ],
  },
};

export type Chapter = {
  id: string;
  tab: string;
  caption: string;
  /** Variants shown in turn while the chapter is on screen (one = still). */
  main: string[];
  settings?: string[];
};

export const CHAPTERS: Chapter[] = [
  { id: 'window', tab: 'Window', caption: 'One window. A big Start button and your car, live.', main: ['waiting', 'extend', 'mirror'] },
  { id: 'menu', tab: 'Menu bar', caption: 'Control Center–style, one click away. Or skip the Dock.', main: ['extend'] },
  { id: 'setup', tab: 'Setup', caption: 'Permissions, network, the address. Three steps, once.', main: ['setup-1', 'setup-2', 'setup-3'] },
  { id: 'guide', tab: 'Guide', caption: 'The recommended way to connect, checked off live.', main: ['behind'] },
  { id: 'settings', tab: 'Settings', caption: 'General, Display, Network, Advanced.', main: ['behind'], settings: ['general', 'display', 'network', 'advanced'] },
];

/** Where a window sits (its body's top-left, in points) and whether it shows, per chapter. */
export type Place = { x: number; y: number; on: boolean };

type LayoutSpec = {
  width: number;
  height: number;
  /** Menu bar height, in points. */
  bar: number;
  places: Record<Layer, Place[]>;
};

const hidden = (x: number, y: number): Place => ({ x, y, on: false });

export const LAYOUTS: Record<LayoutName, LayoutSpec> = {
  wide: {
    width: 1200,
    height: 750,
    bar: 26,
    places: {
      main: [
        { x: 370, y: 104, on: true },
        { x: 250, y: 104, on: true },
        { x: 370, y: 104, on: true },
        { x: 196, y: 112, on: true },
        { x: 196, y: 112, on: true },
      ],
      panel: [hidden(894, 21), { x: 894, y: 31, on: true }, hidden(894, 21), hidden(894, 21), hidden(894, 21)],
      guide: [hidden(530, 120), hidden(530, 120), hidden(530, 120), { x: 530, y: 42, on: true }, hidden(530, 110)],
      settings: [hidden(640, 72), hidden(640, 72), hidden(640, 72), hidden(640, 72), { x: 580, y: 72, on: true }],
    },
  },
  tall: {
    width: 640,
    height: 880,
    bar: 26,
    places: {
      main: [
        { x: 90, y: 128, on: true },
        { x: 34, y: 284, on: true },
        { x: 90, y: 128, on: true },
        { x: 90, y: 56, on: true },
        { x: 90, y: 56, on: true },
      ],
      panel: [hidden(334, 21), { x: 334, y: 31, on: true }, hidden(334, 21), hidden(334, 21), hidden(334, 21)],
      guide: [hidden(30, 230), hidden(30, 230), hidden(30, 230), { x: 30, y: 150, on: true }, hidden(30, 220)],
      settings: [hidden(100, 220), hidden(100, 220), hidden(100, 220), hidden(100, 220), { x: 60, y: 200, on: true }],
    },
  },
};

export const src = (file: string, look: Look, density: 1 | 2) => `/shots/${file}-${look}@${density}x.webp`;
