import type { CSSProperties } from 'react';

/** "Sound through the car speakers": appears while the film plays in cinema playout. */
export function SoundCue({ on, style }: { on: boolean; style?: CSSProperties }) {
  return (
    <div className={'dm-snd' + (on ? ' dm-on' : '')} style={style} aria-hidden={!on}>
      <span className="dm-snd-bars" aria-hidden="true">
        <i />
        <i />
        <i />
        <i />
      </span>
      Sound through the car speakers
    </div>
  );
}
