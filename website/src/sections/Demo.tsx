import { useState } from 'react';
import { DemoStage } from '../demo';
import { Segmented } from '../ui/Segmented';
import { MediaRow, type Stat } from './MediaRow';

type Display = 'extend' | 'mirror';
type Tier = 'mcu2' | 'mcu3';

const DISPLAY: { id: Display; label: string; caption: string }[] = [
  { id: 'extend', label: 'Extend', caption: 'A second display, sized to the car' },
  { id: 'mirror', label: 'Mirror', caption: 'The screen you’re on' },
];

const TIER: { id: Tier; label: string; caption: string }[] = [
  { id: 'mcu2', label: 'MCU2', caption: 'MCU2 · 720p30 H.264' },
  { id: 'mcu3', label: 'MCU3', caption: 'MCU3 · 1080p60 HEVC' },
];

const STATS: Stat[] = [
  { value: '60', unit: 'fps', label: 'on MCU3', icon: 'play' },
  { value: '48', unit: 'kHz', label: 'stereo, in sync', icon: 'sound' },
];

/** #demo: the live car screen as the media of a "media + content row", paired with the Mac app below it. */
export function Demo() {
  const [display, setDisplay] = useState<Display>('extend');
  const [tier, setTier] = useState<Tier>('mcu3');
  const d = DISPLAY.find((x) => x.id === display)!;
  const t = TIER.find((x) => x.id === tier)!;

  return (
    <MediaRow
      id="demo"
      className="demo-row"
      title="Your Mac, on the big screen"
      sub={<>Tap, drag or scroll the car&rsquo;s screen. Inside the browser is the real Dashcast client.</>}
      media={<DemoStage display={display} tier={tier} />}
      controls={
        <>
          <Segmented label="Display" items={DISPLAY} value={display} onChange={setDisplay} />
          <Segmented label="Car computer" items={TIER} value={tier} onChange={setTier} />
        </>
      }
      caption={`${d.caption} · ${t.caption}`}
      note="For use while parked, charging, or by a passenger."
      stats={STATS}
    />
  );
}
