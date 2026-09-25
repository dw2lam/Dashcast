import { useEffect, useRef } from 'react';
import { useDemo } from './useDemo';
import type { TierId } from './client/stats';
import type { DisplayMode } from './mac/desktop';
import './demo.css';

export interface DemoStageProps {
  display: DisplayMode;
  tier: TierId;
  stats?: boolean;
}

/**
 * The live car screen straight on: bezel and rounded glass, Theater, the Mac desktop streaming its calm
 * loop. Fills its positioned parent (16:10). Controlled: prop changes swap the stream behind a brief
 * dip to black. Tap, drag and scroll drive the Mac.
 */
export function DemoStage({ display, tier, stats = false }: DemoStageProps) {
  const { host, handle } = useDemo({
    display,
    tier,
    stats,
    story: 'loop',
    autoplay: true,
    interactive: true,
    framing: 'screen',
    eager: false,
  });
  const applied = useRef({ display, tier });

  useEffect(() => {
    if (!handle) return;
    const a = applied.current;
    if (a.display === display && a.tier === tier) return;
    applied.current = { display, tier };
    handle.stage.fade(() => {
      handle.screen.setDisplay(display);
      handle.screen.setTier(tier);
    });
  }, [handle, display, tier]);

  useEffect(() => {
    if (handle) handle.screen.setStats(stats);
  }, [handle, stats]);

  return (
    <div
      ref={host}
      className="dm-dstage"
      role="img"
      aria-label="A Tesla's centre screen showing a Mac desktop through Dashcast. Tap, drag or scroll it."
    />
  );
}
