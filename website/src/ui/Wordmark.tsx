import { useId } from 'react';

/** Dashcast mark (the app icon's wide car display + small Mac pane) beside the name. */
export function Mark({ size = 20 }: { size?: number }) {
  const id = useId().replace(/:/g, '');
  return (
    <svg className="mark" width={(size * 28) / 20} height={size} viewBox="0 0 28 20" aria-hidden="true">
      <defs>
        <linearGradient id={`g${id}`} x1="0" y1="1" x2="1" y2="0">
          <stop offset="0" stopColor="#0872FE" />
          <stop offset="0.55" stopColor="#15ABFE" />
          <stop offset="1" stopColor="#18D3FD" />
        </linearGradient>
      </defs>
      <rect x="6" y="2" width="21" height="10.5" rx="2.2" fill={`url(#g${id})`} />
      <rect x="1" y="8" width="13.2" height="9.4" rx="1.9" fill="#fff" stroke="#8A96AB" strokeOpacity="0.55" strokeWidth="0.8" />
      <rect x="2.7" y="9.7" width="9.8" height="6" rx="0.9" fill={`url(#g${id})`} />
    </svg>
  );
}

export function Wordmark() {
  return (
    <span className="wordmark">
      <Mark />
      <span className="wordmark__name">Dashcast</span>
    </span>
  );
}
