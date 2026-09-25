import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import gsap from 'gsap';
import { useDemo } from './useDemo';
import type { Cue } from './screen';
import type { TierId } from './client/stats';
import type { DisplayMode } from './mac/desktop';
import { SoundCue } from './SoundCue';
import './demo.css';

type View = 'cabin' | 'screen';

interface Option<T extends string> {
  value: T;
  label: string;
  sub?: string;
}

function Segmented<T extends string>({ label, value, options, onChange }: { label: string; value: T; options: Option<T>[]; onChange: (v: T) => void }) {
  const wrap = useRef<HTMLDivElement>(null);
  const pill = useRef<HTMLSpanElement>(null);
  useLayoutEffect(() => {
    const w = wrap.current;
    const p = pill.current;
    if (!w || !p) return;
    const place = () => {
      const on = w.querySelector<HTMLButtonElement>('button[aria-pressed="true"]');
      if (!on) return;
      p.style.width = on.offsetWidth + 'px';
      p.style.transform = `translateX(${on.offsetLeft}px)`;
    };
    place();
    const ro = new ResizeObserver(place);
    ro.observe(w);
    return () => ro.disconnect();
  }, [value]);
  return (
    <div className="dm-seg" role="group" aria-label={label}>
      <span className="dm-seg-label">{label}</span>
      <div className="dm-seg-track" ref={wrap}>
        <span className="dm-seg-pill" ref={pill} aria-hidden="true" />
        {options.map((o) => (
          <button key={o.value} type="button" aria-pressed={o.value === value} onClick={() => onChange(o.value)}>
            {o.label}
            {o.sub && <small>{o.sub}</small>}
          </button>
        ))}
      </div>
    </div>
  );
}

/** The #demo section: the cabin (or the screen straight on), live and touchable, with its controls. */
export function DemoSection() {
  const [view, setView] = useState<View>('cabin');
  const [display, setDisplay] = useState<DisplayMode>('extend');
  const [tier, setTier] = useState<TierId>('mcu2');
  const [stats, setStats] = useState(false);
  const [cue, setCue] = useState<Cue>('connect');
  const { host, handle } = useDemo({
    display: 'extend',
    tier: 'mcu2',
    stats: false,
    autoplay: true,
    interactive: true,
    framing: 'section',
    eager: false,
    onCue: setCue,
  });
  const viewT = useRef({ v: 0 });
  const [anchor, setAnchor] = useState<[number, number] | null>(null);

  useEffect(() => {
    if (handle) handle.screen.setDisplay(display);
  }, [handle, display]);
  useEffect(() => {
    if (handle) handle.screen.setTier(tier);
  }, [handle, tier]);
  useEffect(() => {
    if (handle) handle.screen.setStats(stats);
  }, [handle, stats]);

  useEffect(() => {
    if (!handle) return;
    const stage = handle.stage;
    stage.onLayout(() => {
      const q = stage.quad();
      const el = host.current;
      if (!q || !el) return;
      // Under the screen when there's room, else floating just inside its bottom edge.
      const y = Math.max(q[2][1], q[3][1]);
      setAnchor([(q[2][0] + q[3][0]) / 2, el.clientHeight - y >= 60 ? y : y - 62]);
    });
    stage.layout();
  }, [handle, host]);

  useEffect(() => {
    if (!handle) return;
    const target = view === 'screen' ? 1 : 0;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      viewT.current.v = target;
      handle.stage.setView(target);
      return;
    }
    const tw = gsap.to(viewT.current, { v: target, duration: 1.1, ease: 'power3.inOut', onUpdate: () => handle.stage.setView(viewT.current.v) });
    return () => {
      tw.kill();
    };
  }, [handle, view]);

  return (
    <section id="demo" className="dm-demo">
      <header className="dm-demo-head">
        <h2>Your Mac, on the big screen</h2>
        <p>Tap, drag or scroll the car&rsquo;s screen. Inside the browser is the real Dashcast client.</p>
      </header>
      <div
        ref={host}
        className="dm-cab dm-cab-touch dm-demo-stage"
        data-view={view}
        role="img"
        aria-label="A Tesla's centre screen showing a Mac desktop through Dashcast. Tap, drag or scroll it."
      >
        {anchor && <SoundCue on={cue === 'sound'} style={{ left: anchor[0], top: anchor[1] }} />}
      </div>
      <div className="dm-demo-controls">
        <Segmented<View>
          label="View"
          value={view}
          onChange={setView}
          options={[
            { value: 'cabin', label: 'Cabin' },
            { value: 'screen', label: 'Screen' },
          ]}
        />
        <Segmented<DisplayMode>
          label="Display"
          value={display}
          onChange={setDisplay}
          options={[
            { value: 'extend', label: 'Extend' },
            { value: 'mirror', label: 'Mirror' },
          ]}
        />
        <Segmented<TierId>
          label="Car computer"
          value={tier}
          onChange={setTier}
          options={[
            { value: 'mcu2', label: 'MCU2', sub: '720p30 H.264' },
            { value: 'mcu3', label: 'MCU3', sub: '1080p60 HEVC' },
          ]}
        />
        <div className="dm-demo-actions">
          <button type="button" className="dm-demo-link" aria-pressed={stats} onClick={() => setStats(!stats)}>
            {stats ? 'Hide stats' : 'Show stats'}
          </button>
          <button type="button" className="dm-demo-link" onClick={() => handle && handle.screen.restart()}>
            Replay
          </button>
        </div>
      </div>
      <p className="dm-demo-note">
        For use while parked, charging, or by a passenger.
        {stats && ' The stats overlay shows numbers from a local test on a Mac, not from a car.'}
      </p>
    </section>
  );
}
