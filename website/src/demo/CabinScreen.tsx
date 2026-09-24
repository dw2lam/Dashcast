import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { useDemo } from './useDemo';
import type { Cue, Story } from './screen';
import { HERO_BOTTOM, type Framing } from './stage';
import { SoundCue } from './SoundCue';
import './demo.css';

export interface CabinScreenProps {
  autoplay?: boolean;
  interactive?: boolean;
  /**
   * 'hero' (default): the car screen sits in the band between a title block (~260 px from the top)
   * and a stats row (~110 px from the bottom), centred in it, on every aspect ratio.
   * 'section': centred and larger.
   */
  framing?: Framing;
  /**
   * 'loop' (default with the hero framing): opens on the payoff, the streaming desktop with the film
   * playing, as a calm 10 s loop. 'full': the 30 s connect story (the #demo default).
   */
  story?: Story;
  /** The "Sound through the car speakers" chip under the screen while the film plays (hidden when there's no room). */
  cues?: boolean;
}

const query = typeof location === 'undefined' ? new URLSearchParams() : new URLSearchParams(location.search);
/** `?capture=1`: full viewport over all page chrome, the 10 s seamless loop, window.__dashcastCapture. */
const CAPTURE = query.has('capture') && query.get('capture') !== '0';

/**
 * The real cabin photo with the live car screen composited onto its glass. Fills its positioned
 * parent (position: absolute; inset: 0).
 */
export function CabinScreen(props: CabinScreenProps) {
  const inner = <Cabin {...props} />;
  return CAPTURE ? createPortal(inner, document.body) : inner;
}

function Cabin({ autoplay = true, interactive = false, framing = 'hero', story, cues = true }: CabinScreenProps) {
  const [cue, setCue] = useState<Cue>('connect');
  const kind: Framing = CAPTURE ? (query.get('framing') === 'section' ? 'section' : 'hero') : framing;
  const { host, handle } = useDemo({
    display: 'extend',
    tier: 'mcu2',
    stats: false,
    autoplay,
    interactive,
    framing: kind,
    story: CAPTURE ? 'loop' : story || (framing === 'hero' ? 'loop' : 'full'),
    eager: true,
    capture: CAPTURE,
    onCue: setCue,
  });
  const [anchor, setAnchor] = useState<[number, number] | null>(null);

  useEffect(() => {
    if (!handle) return;
    const update = () => {
      const q = handle.stage.quad();
      const el = host.current;
      if (!q || !el) return;
      const y = Math.max(q[2][1], q[3][1]);
      const room = el.clientHeight - (kind === 'hero' && !CAPTURE ? HERO_BOTTOM : 0) - y;
      setAnchor(room > 60 ? [(q[2][0] + q[3][0]) / 2, y] : null);
    };
    handle.stage.onLayout(update);
    update();
  }, [handle, host, kind]);

  return (
    <div
      ref={host}
      className={'dm-cab' + (interactive ? ' dm-cab-touch' : '') + (CAPTURE ? ' dm-cab-capture' : '')}
      aria-hidden={!interactive}
    >
      {cues && !(CAPTURE && query.get('cues') === '0') && anchor && <SoundCue on={cue === 'sound'} style={{ left: anchor[0], top: anchor[1] }} />}
    </div>
  );
}
