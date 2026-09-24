import { useCallback, useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent } from 'react';
import { Topology, type Mode } from './Topology';
import { revealWithin } from '../lib/motion';
import { CAR_ADDRESS } from '../lib/links';
import './Connect.css';

type Method = {
  id: Mode;
  tab: string;
  kicker: string;
  kickerTone: 'blue' | 'neutral' | 'negative';
  title: string;
  body: string;
  steps?: string[];
};

const METHODS: Method[] = [
  {
    id: 'hotspot',
    tab: 'Mac as Hotspot',
    kicker: 'Recommended',
    kickerTone: 'blue',
    title: 'Mac as Hotspot',
    body: 'One hop from Mac to car, so it has the lowest latency.',
    steps: [
      'Plug your iPhone into the Mac for internet. Optional.',
      'Turn on Internet Sharing. The Mac makes its own Wi‑Fi.',
      'Join that Wi‑Fi from the car.',
    ],
  },
  {
    id: 'router',
    tab: 'Travel Router',
    kicker: 'Most reliable',
    kickerTone: 'neutral',
    title: 'Travel Router',
    body: 'A small router such as a GL.iNet. Dashcast writes its setup for you.',
    steps: ['Power the router in the car.', 'Apply the setup Dashcast generates.', 'Join its Wi‑Fi from the Mac and the car.'],
  },
  {
    id: 'phone',
    tab: 'iPhone Hotspot',
    kicker: 'Not supported',
    kickerTone: 'negative',
    title: 'iPhone Hotspot for both',
    body: 'Since iOS 18, devices on an iPhone hotspot can’t reach each other, so the car never finds the Mac.',
  },
];

const IN_CAR: { title: string; note?: string }[] = [
  { title: 'Join the Mac’s Wi‑Fi' },
  { title: 'Open the Browser' },
  { title: `Go to ${CAR_ADDRESS}`, note: 'or your own hostname' },
  { title: 'Tap to Start', note: 'the tap turns on sound' },
  { title: 'Go fullscreen' },
];

export function Connect() {
  const root = useRef<HTMLElement>(null);
  const tabsRef = useRef<HTMLDivElement>(null);
  const pillRef = useRef<HTMLSpanElement>(null);
  const [mode, setMode] = useState<Mode>('hotspot');
  const method = METHODS.find((m) => m.id === mode)!;

  const movePill = useCallback((animate: boolean) => {
    const tabs = tabsRef.current;
    const pill = pillRef.current;
    const btn = tabs?.querySelector<HTMLElement>('[aria-selected="true"]');
    if (!tabs || !pill || !btn) return;
    if (!animate) pill.style.transition = 'none';
    pill.style.width = `${btn.offsetWidth}px`;
    pill.style.transform = `translateX(${btn.offsetLeft}px)`;
    if (!animate) {
      void pill.offsetWidth;
      pill.style.transition = '';
    }
  }, []);

  useLayoutEffect(() => movePill(true), [mode, movePill]);

  useEffect(() => {
    const onResize = () => movePill(false);
    window.addEventListener('resize', onResize);
    document.fonts?.ready.then(() => movePill(false));
    return () => window.removeEventListener('resize', onResize);
  }, [movePill]);

  useEffect(() => (root.current ? revealWithin(root.current) : undefined), []);

  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    const i = METHODS.findIndex((m) => m.id === mode);
    const next = e.key === 'ArrowRight' ? i + 1 : e.key === 'ArrowLeft' ? i - 1 : -9;
    if (next === -9) return;
    e.preventDefault();
    const m = METHODS[(next + METHODS.length) % METHODS.length];
    setMode(m.id);
    tabsRef.current?.querySelector<HTMLElement>(`[data-mode="${m.id}"]`)?.focus();
  };

  return (
    <section id="connect" className="section connect" ref={root} aria-labelledby="connect-title">
      <div className="wrap">
        <header className="section-head">
          <h2 id="connect-title" className="t-section" data-reveal="large">
            Connect
          </h2>
          <p className="t-sub" data-reveal="small" data-reveal-delay="0.1">
            Your Mac makes the Wi‑Fi. The car joins it.
          </p>
        </header>

        <div className="tabs" role="tablist" aria-label="Connection method" ref={tabsRef} onKeyDown={onKey} data-reveal="small" data-reveal-delay="0.15">
          <span className="tabs__pill" ref={pillRef} aria-hidden="true" />
          {METHODS.map((m) => (
            <button
              key={m.id}
              type="button"
              role="tab"
              id={`tab-${m.id}`}
              data-mode={m.id}
              aria-selected={mode === m.id}
              aria-controls="connect-panel"
              tabIndex={mode === m.id ? 0 : -1}
              className="tabs__tab"
              onClick={() => setMode(m.id)}
            >
              {m.tab}
            </button>
          ))}
        </div>

        <div className="connect__panel" id="connect-panel" role="tabpanel" aria-labelledby={`tab-${mode}`} data-reveal="small" data-reveal-delay="0.2">
          <div className="connect__diagram">
            <Topology mode={mode} />
          </div>
          <div className="connect__copy" key={mode}>
            <p className={`kicker kicker--${method.kickerTone}`}>{method.kicker}</p>
            <h3 className="t-title connect__title">{method.title}</h3>
            <p className="t-body connect__body">{method.body}</p>
            {method.steps && (
              <ol className="steps">
                {method.steps.map((s, i) => (
                  <li key={s}>
                    <span className="steps__n">{i + 1}</span>
                    <span>{s}</span>
                  </li>
                ))}
              </ol>
            )}
            {!method.steps && (
              <p className="t-body connect__alt">
                Use the iPhone for the Mac&rsquo;s internet over USB, and let the Mac be the hotspot.
              </p>
            )}
          </div>
        </div>

        <div className="incar">
          <h3 className="t-title incar__title" data-reveal="small">
            In the car
          </h3>
          <ol className="incar__steps">
            {IN_CAR.map((s, i) => (
              <li key={s.title} data-reveal="small" data-reveal-delay={String(0.06 * i)}>
                <span className="incar__n">{i + 1}</span>
                <span className="incar__text">{s.title}</span>
                {s.note && <span className="incar__note">{s.note}</span>}
              </li>
            ))}
          </ol>
        </div>
      </div>
    </section>
  );
}
