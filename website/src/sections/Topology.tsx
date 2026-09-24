import { useId } from 'react';

export type Mode = 'hotspot' | 'router' | 'phone';

/** Node x positions per connection method; nodes glide between them when the tab changes. */
const LAYOUT: Record<Mode, { phone: number; mac: number; router: number; car: number; show: { phone: number; router: number } }> = {
  hotspot: { phone: 78, mac: 262, router: 380, car: 486, show: { phone: 1, router: 0 } },
  router: { phone: -60, mac: 104, router: 300, car: 486, show: { phone: 0, router: 1 } },
  phone: { phone: 300, mac: 104, router: 380, car: 486, show: { phone: 1, router: 0 } },
};

const Y = 132;

function Dots({ x1, x2, n = 3, dur = 1.6, reverse = false, className = '' }: { x1: number; x2: number; n?: number; dur?: number; reverse?: boolean; className?: string }) {
  const start = reverse ? x2 : x1;
  const d = reverse ? x1 - x2 : x2 - x1;
  return (
    <g className={`topo__dots ${className}`}>
      {Array.from({ length: n }, (_, i) => (
        <circle
          key={i}
          cx={start}
          cy={Y}
          r={reverse ? 2.6 : 3.4}
          style={{ ['--d' as string]: `${d}px`, animationDuration: `${dur}s`, animationDelay: `${(-dur * i) / n}s` }}
        />
      ))}
    </g>
  );
}

function WifiArcs({ x, y }: { x: number; y: number }) {
  return (
    <g className="topo__wifi" transform={`translate(${x} ${y})`}>
      <path d="M-9 -2a13 13 0 0 1 18 0" />
      <path d="M-15 -8a21 21 0 0 1 30 0" />
      <path d="M-21 -14a29 29 0 0 1 42 0" />
    </g>
  );
}

export function Topology({ mode }: { mode: Mode }) {
  const id = useId().replace(/:/g, '');
  const L = LAYOUT[mode];
  const on = (m: Mode | Mode[]) => ((Array.isArray(m) ? m.includes(mode) : m === mode) ? 1 : 0);
  const node = (x: number, visible = 1) => ({ transform: `translate(${x}px, ${Y}px)`, opacity: visible });

  return (
    <svg className="topo" viewBox="0 6 580 206" role="img" aria-label={DESCRIPTIONS[mode]}>
      <defs>
        <linearGradient id={`b${id}`} x1="0" y1="1" x2="1" y2="0">
          <stop offset="0" stopColor="#0872FE" />
          <stop offset="0.55" stopColor="#15ABFE" />
          <stop offset="1" stopColor="#18D3FD" />
        </linearGradient>
      </defs>

      {/* links */}
      <g className="topo__layer" style={{ opacity: on('hotspot') }}>
        <line className="topo__cable" x1={78 + 18} y1={Y} x2={262 - 62} y2={Y} />
        <text className="topo__tag" x={(78 + 18 + 262 - 62) / 2} y={Y - 12}>USB</text>
        <line className="topo__air" x1={262 + 62} y1={Y} x2={486 - 66} y2={Y} />
        <text className="topo__tag" x={(262 + 62 + 486 - 66) / 2} y={Y - 14}>Wi‑Fi</text>
        <Dots x1={262 + 64} x2={486 - 68} />
        <Dots x1={262 + 64} x2={486 - 68} n={2} dur={2.2} reverse className="topo__dots--back" />
      </g>

      <g className="topo__layer" style={{ opacity: on('router') }}>
        <line className="topo__air" x1={104 + 62} y1={Y} x2={300 - 40} y2={Y} />
        <line className="topo__air" x1={300 + 40} y1={Y} x2={486 - 66} y2={Y} />
        <Dots x1={104 + 64} x2={300 - 42} n={2} dur={1.1} />
        <Dots x1={300 + 42} x2={486 - 68} n={2} dur={1.1} />
        <Dots x1={300 + 42} x2={486 - 68} n={1} dur={1.8} reverse className="topo__dots--back" />
      </g>

      <g className="topo__layer" style={{ opacity: on('phone') }}>
        <line className="topo__air topo__air--muted" x1={104 + 62} y1={Y} x2={300 - 26} y2={Y} />
        <line className="topo__air topo__air--muted" x1={300 + 26} y1={Y} x2={486 - 66} y2={Y} />
        <path className="topo__blocked" d={`M${104} ${Y - 46} C ${200} ${Y - 128}, ${390} ${Y - 128}, ${486} ${Y - 50}`} />
        <g transform={`translate(${295} ${Y - 107})`} className="topo__x">
          <circle r="12" />
          <path d="M-4.5 -4.5l9 9M4.5 -4.5l-9 9" />
        </g>
      </g>

      {/* nodes */}
      <g className="topo__node" style={node(L.phone, L.show.phone)}>
        <rect x="-17" y="-32" width="34" height="64" rx="7" className="topo__body" />
        <line x1="-5" y1="-26" x2="5" y2="-26" className="topo__stroke" />
        <g style={{ opacity: on('phone') }}>
          <WifiArcs x={0} y={-42} />
        </g>
        <text className="topo__label" y="58">iPhone</text>
      </g>

      <g className="topo__node" style={node(L.router, L.show.router)}>
        <line x1="-20" y1="-12" x2="-26" y2="-34" className="topo__stroke" />
        <line x1="20" y1="-12" x2="26" y2="-34" className="topo__stroke" />
        <rect x="-36" y="-14" width="72" height="30" rx="6" className="topo__body" />
        <circle cx="-20" cy="1" r="2" className="topo__led" />
        <circle cx="-12" cy="1" r="2" className="topo__led" />
        <WifiArcs x={0} y={-44} />
        <text className="topo__label" y="58">Travel router</text>
      </g>

      <g className="topo__node" style={node(L.mac)}>
        <rect x="-50" y="-38" width="100" height="66" rx="5" className="topo__body" />
        <rect x="-44" y="-32" width="88" height="54" rx="2" fill={`url(#b${id})`} />
        <path d="M-62 28h124l-6 8h-112z" className="topo__body" />
        <g style={{ opacity: on('hotspot') }}>
          <WifiArcs x={0} y={-50} />
        </g>
        <text className="topo__label" y="58">Mac</text>
      </g>

      <g className="topo__node" style={node(L.car)}>
        <rect x="-64" y="-42" width="128" height="80" rx="9" className="topo__body" />
        <rect x="-57" y="-35" width="114" height="66" rx="4" className="topo__screen-off" />
        <rect x="-57" y="-35" width="114" height="66" rx="4" fill={`url(#b${id})`} className="topo__screen" style={{ opacity: on(['hotspot', 'router']) }} />
        <rect x="-7" y="38" width="14" height="10" className="topo__body" />
        <text className="topo__label" y="66">Tesla</text>
      </g>
    </svg>
  );
}

const DESCRIPTIONS: Record<Mode, string> = {
  hotspot: 'iPhone connects to the Mac over USB; the Mac shares Wi-Fi and the Tesla joins it, one hop from Mac to car.',
  router: 'The Mac and the Tesla both join a travel router’s Wi-Fi; the stream passes through the router.',
  phone: 'Mac and Tesla both on an iPhone hotspot: the phone keeps them apart, so the car cannot reach the Mac.',
};
