// Owned by the Tesla-demo agent. Contract (keep these exports):
//   CabinScreen  — just the real cabin photo with the live screen composited in; fills its parent
//                  (position:absolute; inset:0 friendly). Props: { autoplay?: boolean; interactive?: boolean }
//   DemoStage    — the live car screen alone (straight on, Theater, calm loop), filling a 16:10 parent.
//                  Props: { display: 'extend' | 'mirror'; tier: 'mcu2' | 'mcu3'; stats?: boolean }
export { DemoStage } from './DemoStage';
export type { DemoStageProps } from './DemoStage';
export { CabinScreen } from './CabinScreen';
//   SoundVisual  — Features "Sound through the car" media: fills its positioned parent. No props.
//   McuVisual    — Features "Built for MCU2 and MCU3" media: fills its positioned parent. No props.
export { SoundVisual } from './visuals/SoundVisual';
export { McuVisual } from './visuals/McuVisual';
