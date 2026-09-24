import { useEffect, useRef } from 'react';
import { Mark } from '../ui/Wordmark';
import { revealWithin } from '../lib/motion';
import './Compare.css';

type Cell = { mark?: 'yes' | 'no'; value: string; note?: string };
type Row = { label: string; us: Cell; them: Cell };

// Only published, verifiable facts about popular browser display apps (checked September 2026). No latency row:
// there are no in-car numbers to compare against.
const ROWS: Row[] = [
  {
    label: 'Price',
    us: { value: 'Free', note: 'and open source' },
    them: { value: '60 min a week free', note: 'then a yearly subscription' },
  },
  {
    label: 'Sound through the car speakers',
    us: { mark: 'yes', value: 'Yes', note: 'In sync with the video' },
    them: { mark: 'no', value: 'No' },
  },
  {
    label: 'Keyboard',
    us: { mark: 'yes', value: 'Yes' },
    them: { mark: 'no', value: 'No' },
  },
  {
    label: 'Video',
    us: { value: 'H.264 High or HEVC', note: 'Up to 60 fps, tuned live to your car' },
    them: { value: 'H.264 Baseline' },
  },
  {
    label: 'Works without internet',
    us: { mark: 'yes', value: 'Yes', note: 'The Mac answers the car’s DNS' },
    them: { mark: 'no', value: 'No', note: 'Needs your phone’s hotspot' },
  },
  {
    label: 'Open source',
    us: { mark: 'yes', value: 'Yes', note: 'MIT license' },
    them: { mark: 'no', value: 'No' },
  },
];

function MarkIcon({ kind }: { kind: 'yes' | 'no' }) {
  return kind === 'yes' ? (
    <svg className="cmp__icon cmp__icon--yes" width="20" height="20" viewBox="0 0 20 20" aria-hidden="true">
      <circle cx="10" cy="10" r="10" />
      <path d="M5.8 10.3l2.8 2.8 5.6-6" fill="none" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  ) : (
    <svg className="cmp__icon cmp__icon--no" width="20" height="20" viewBox="0 0 20 20" aria-hidden="true">
      <path d="M6 10h8" fill="none" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  );
}

function CellView({ cell, us }: { cell: Cell; us?: boolean }) {
  return (
    <div className={`cmp__cell${us ? ' cmp__cell--us' : ''}`} role="cell">
      {cell.mark && <MarkIcon kind={cell.mark} />}
      <span className="cmp__text">
        <span className="cmp__value">{cell.value}</span>
        {cell.note && <span className="cmp__note">{cell.note}</span>}
      </span>
    </div>
  );
}

/** tesla.com /compare pattern: columns of values per product, a label per row, quiet marks, sparse words. */
export function Compare() {
  const root = useRef<HTMLElement>(null);
  useEffect(() => (root.current ? revealWithin(root.current) : undefined), []);

  return (
    <section id="compare" className="compare section" ref={root} aria-labelledby="compare-title">
      <div className="wrap compare__wrap">
        <header className="section-head">
          <h2 id="compare-title" className="t-section" data-reveal="large">
            How it compares
          </h2>
          <p className="t-sub compare__sub" data-reveal="small" data-reveal-delay="0.1">
            Free, open source, and no cloud in between.
          </p>
        </header>

        <div className="cmp" role="table" aria-label="Dashcast compared with other browser display apps">
          <div className="cmp__head" role="row" data-reveal="small">
            <span className="cmp__corner" role="columnheader">
              <span className="sr-only">Feature</span>
            </span>
            <span className="cmp__name cmp__name--us" role="columnheader">
              <Mark size={16} />
              <span>Dashcast</span>
            </span>
            <span className="cmp__name" role="columnheader">
              Others
            </span>
          </div>
          {ROWS.map((r, i) => (
            <div className="cmp__row" role="row" key={r.label} data-reveal="small" data-reveal-delay={String(0.05 * i)}>
              <span className="cmp__label" role="rowheader">
                {r.label}
              </span>
              <CellView cell={r.us} us />
              <CellView cell={r.them} />
            </div>
          ))}
        </div>

        <p className="compare__foot">Compared with the published features of popular browser display apps, September 2026.</p>
      </div>
    </section>
  );
}
