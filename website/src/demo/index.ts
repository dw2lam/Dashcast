// Owned by the Tesla-demo agent. Contract (keep these exports):
//   DemoSection  — the full #demo section (heading, controls, the in-car demo).
//   CabinScreen  — just the real cabin photo with the live screen composited in; fills its parent
//                  (position:absolute; inset:0 friendly). Props: { autoplay?: boolean; interactive?: boolean }
export { DemoSection } from './DemoSection';
export { CabinScreen } from './CabinScreen';
//   SoundVisual  — Features "Sound through the car" media: fills its positioned parent. No props.
//   McuVisual    — Features "Built for MCU2 and MCU3" media: fills its positioned parent. No props.
export { SoundVisual } from './visuals/SoundVisual';
export { McuVisual } from './visuals/McuVisual';
