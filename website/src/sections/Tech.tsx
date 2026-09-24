import { useEffect, useRef } from 'react';
import { revealWithin } from '../lib/motion';
import { CAR_ADDRESS } from '../lib/links';
import './Tech.css';

const WHY = [
  { label: 'Why a home server fails', value: 'The Tesla browser refuses private addresses: 192.168.x, 10.x and 172.16–31.x.' },
  { label: 'What Dashcast does', value: `It serves from ${CAR_ADDRESS}, a reserved documentation address that isn’t private, bound to the Mac itself.` },
  { label: 'Offline by design', value: 'The Mac answers the car’s DNS and its connectivity check, so no internet is needed.' },
];

const MODES = [
  {
    name: 'Secure',
    what: 'HTTPS on your own domain, with a free Let’s Encrypt certificate.',
    why: 'Unlocks WebCodecs, the lowest-latency path.',
  },
  {
    name: 'Compatibility',
    what: `Plain http://${CAR_ADDRESS}, streamed over WebRTC.`,
    why: 'No setup needed.',
  },
];

const TIERS = [
  { tier: 'MCU2 Low', codec: 'JPEG', res: '960 × 540', fps: '30' },
  { tier: 'MCU2', codec: 'H.264 Main', res: '1280 × 720', fps: '30' },
  { tier: 'MCU2 High', codec: 'H.264 Main', res: '1920 × 1080', fps: '30' },
  { tier: 'MCU3', codec: 'H.264 High', res: '1920 × 1200', fps: '60' },
  { tier: 'MCU3 HEVC', codec: 'HEVC', res: '1920 × 1200', fps: '60' },
];

const BENCH = [
  { label: 'HEVC 1920 × 1198', value: '57 fps' },
  { label: 'Decode', value: '≈ 1.1 ms' },
  { label: 'End to end', value: '≈ 8.5 ms' },
  { label: 'MCU2 tier', value: '29 fps · ≈ 3.7 ms' },
  { label: 'Cinema A/V offset', value: '≈ 2 ms' },
];

export function Tech() {
  const root = useRef<HTMLElement>(null);
  useEffect(() => (root.current ? revealWithin(root.current) : undefined), []);

  return (
    <section id="tech" className="section tech on-dark" ref={root} aria-labelledby="tech-title">
      <div className="wrap">
        <header className="section-head">
          <h2 id="tech-title" className="t-section" data-reveal="large">
            Under the hood
          </h2>
          <p className="t-sub" data-reveal="small" data-reveal-delay="0.1">
            No cloud, no internet, nothing installed in the car.
          </p>
        </header>

        <div className="tech__address" data-reveal="large">
          <p className="tech__ip">{CAR_ADDRESS}</p>
          <p className="t-label">The address your car opens</p>
        </div>

        <dl className="tech__grid tech__grid--3">
          {WHY.map((w, i) => (
            <div className="spec" key={w.label} data-reveal="small" data-reveal-delay={String(i * 0.08)}>
              <dt className="spec__label">{w.label}</dt>
              <dd className="spec__value">{w.value}</dd>
            </div>
          ))}
        </dl>

        <div className="tech__block">
          <h3 className="tech__h" data-reveal="small">
            Two modes, picked automatically
          </h3>
          <div className="tech__modes">
            {MODES.map((m, i) => (
              <div className="mode" key={m.name} data-reveal="small" data-reveal-delay={String(i * 0.08)}>
                <p className="mode__name">{m.name}</p>
                <p className="spec__value">{m.what}</p>
                <p className="spec__label mode__why">{m.why}</p>
              </div>
            ))}
          </div>
        </div>

        <div className="tech__block">
          <h3 className="tech__h" data-reveal="small">
            Quality tiers
          </h3>
          <div className="tiers" role="table" aria-label="Quality tiers" data-reveal="small">
            <div className="tiers__row tiers__row--head" role="row">
              <span role="columnheader">Tier</span>
              <span role="columnheader">Codec</span>
              <span role="columnheader">Up to</span>
              <span role="columnheader">fps</span>
            </div>
            {TIERS.map((t) => (
              <div className="tiers__row" role="row" key={t.tier}>
                <span role="cell" className="tiers__tier">
                  {t.tier}
                </span>
                <span role="cell">{t.codec}</span>
                <span role="cell">{t.res}</span>
                <span role="cell">{t.fps}</span>
              </div>
            ))}
          </div>
          <p className="tech__note" data-reveal="small">
            The tier is chosen from the car&rsquo;s measured decode speed, then adjusted live with congestion control. The stream
            matches the car&rsquo;s screen, up to these sizes.
          </p>
        </div>

        <div className="tech__block">
          <h3 className="tech__h" data-reveal="small">
            Measured on a Mac, not in a car
          </h3>
          <dl className="tech__grid tech__grid--5">
            {BENCH.map((b) => (
              <div className="spec" key={b.label} data-reveal="small">
                <dt className="spec__label">{b.label}</dt>
                <dd className="spec__value spec__value--num">{b.value}</dd>
              </div>
            ))}
          </dl>
          <p className="tech__note" data-reveal="small">
            Mac to Chrome on the same Mac, over loopback. Real in-car numbers depend on the car and the Wi‑Fi.
          </p>
        </div>
      </div>
    </section>
  );
}
