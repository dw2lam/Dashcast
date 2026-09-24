import type { ReactNode } from 'react';

/**
 * Animated gesture art for the Touch cards: a small car screen with the Mac on it and fingertips
 * doing the gesture. Pure SVG + CSS keyframes (Touch.css); static under reduced motion.
 */
export type Gesture = 'tap' | 'drag' | 'scroll' | 'hold' | 'keys';

function Screen({ fill, children }: { fill: string; children?: ReactNode }) {
  return (
    <>
      <rect className="g-bezel" x="34" y="44" width="332" height="212" rx="14" />
      <rect className="g-desk" x="42" y="52" width="316" height="196" rx="8" fill={fill} />
      <rect className="g-bar" x="42" y="52" width="316" height="12" rx="0" />
      {children}
    </>
  );
}

function Window({ className = '', lines = 4 }: { className?: string; lines?: number }) {
  return (
    <g className={`g-win ${className}`}>
      <rect className="g-win-body" x="92" y="86" width="176" height="120" rx="7" />
      <circle className="g-dot-r" cx="104" cy="97" r="3" />
      <circle className="g-dot-y" cx="114" cy="97" r="3" />
      <circle className="g-dot-g" cx="124" cy="97" r="3" />
      <g className="g-lines">
        {Array.from({ length: lines }, (_, i) => (
          <rect key={i} className="g-line" x="106" y={116 + i * 18} width={i % 2 ? 118 : 146} height="7" rx="3.5" />
        ))}
      </g>
    </g>
  );
}

function Finger({ className, cx, cy }: { className: string; cx: number; cy: number }) {
  return (
    <g className={`g-finger ${className}`}>
      <circle className="g-ring" cx={cx} cy={cy} r="14" />
      <circle className="g-tip" cx={cx} cy={cy} r="14" />
    </g>
  );
}

export function GestureArt({ kind }: { kind: Gesture }) {
  return (
    <svg className={`g g--${kind}`} viewBox="0 0 400 300" aria-hidden="true">
      <defs>
        <linearGradient id={`gd-${kind}`} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#1d3b7a" />
          <stop offset="0.55" stopColor="#35307a" />
          <stop offset="1" stopColor="#5b2a7a" />
        </linearGradient>
      </defs>
      <g>
        {kind === 'tap' && (
          <Screen fill={`url(#gd-${kind})`}>
            <Window lines={4} />
            <Finger className="g-f1" cx={196} cy={152} />
          </Screen>
        )}
        {kind === 'drag' && (
          <Screen fill={`url(#gd-${kind})`}>
            <g className="g-drag-win">
              <Window lines={4} />
              <Finger className="g-f1" cx={170} cy={98} />
            </g>
          </Screen>
        )}
        {kind === 'scroll' && (
          <Screen fill={`url(#gd-${kind})`}>
            <g>
              <rect className="g-win-body" x="92" y="86" width="176" height="120" rx="7" />
              <svg x="92" y="104" width="176" height="100" viewBox="0 0 176 100">
                <g className="g-scroll-lines">
                  {Array.from({ length: 9 }, (_, i) => (
                    <rect key={i} className="g-line" x="14" y={6 + i * 18} width={i % 2 ? 118 : 146} height="7" rx="3.5" />
                  ))}
                </g>
              </svg>
              <circle className="g-dot-r" cx="104" cy="97" r="3" />
              <circle className="g-dot-y" cx="114" cy="97" r="3" />
              <circle className="g-dot-g" cx="124" cy="97" r="3" />
            </g>
            <Finger className="g-f1" cx={166} cy={186} />
            <Finger className="g-f2" cx={210} cy={192} />
          </Screen>
        )}
        {kind === 'hold' && (
          <Screen fill={`url(#gd-${kind})`}>
            <Window lines={4} />
            <circle className="g-hold-arc" cx="196" cy="152" r="24" />
            <Finger className="g-f1" cx={196} cy={152} />
            <g className="g-menu">
              <rect x="214" y="150" width="96" height="74" rx="6" className="g-menu-body" />
              <rect x="224" y="162" width="62" height="6" rx="3" className="g-line" />
              <rect x="224" y="180" width="72" height="6" rx="3" className="g-line" />
              <rect x="224" y="198" width="54" height="6" rx="3" className="g-line" />
            </g>
          </Screen>
        )}
        {kind === 'keys' && (
          <Screen fill={`url(#gd-${kind})`}>
            <rect className="g-win-body" x="92" y="74" width="216" height="58" rx="7" />
            <rect className="g-field" x="106" y="96" width="188" height="20" rx="4" />
            <rect className="g-typed" x="112" y="102" width="96" height="8" rx="4" />
            <rect className="g-caret" x="210" y="100" width="2" height="12" rx="1" />
            <g className="g-kb">
              {[0, 1, 2].map((row) =>
                Array.from({ length: 10 - row }, (_, i) => (
                  <rect
                    key={`${row}-${i}`}
                    className={`g-key g-key--${(row * 10 + i) % 7}`}
                    x={64 + row * 13 + i * 28}
                    y={152 + row * 26}
                    width="24"
                    height="21"
                    rx="4"
                  />
                )),
              )}
              <rect className="g-key" x="124" y="230" width="152" height="12" rx="4" />
            </g>
          </Screen>
        )}
      </g>
    </svg>
  );
}
