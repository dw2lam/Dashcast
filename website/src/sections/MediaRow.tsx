import type { ReactNode, Ref } from 'react';
import './MediaRow.css';

export type StatIcon = 'play' | 'sound' | 'window' | 'steps';

export type Stat = { value: string; unit?: string; label: string; icon: StatIcon };

type Props = {
  id: string;
  title: string;
  sub: ReactNode;
  /** The 16:10 stage: fills its positioned box. */
  media: ReactNode;
  controls: ReactNode;
  caption?: ReactNode;
  note?: ReactNode;
  stats: Stat[];
  className?: string;
  sectionRef?: Ref<HTMLElement>;
};

function Glyph({ icon }: { icon: StatIcon }) {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      {icon === 'play' && <path d="M5.5 3.8v8.4L12 8z" fill="currentColor" stroke="none" />}
      {icon === 'sound' && (
        <>
          <path d="M3 6.2h2.2L8.4 3.6v8.8L5.2 9.8H3z" fill="currentColor" stroke="none" />
          <path d="M10.6 5.8a3 3 0 0 1 0 4.4M12.4 4.2a5.4 5.4 0 0 1 0 7.6" />
        </>
      )}
      {icon === 'window' && (
        <>
          <rect x="2.5" y="3.5" width="11" height="9" rx="1.6" />
          <path d="M2.5 6.2h11" />
        </>
      )}
      {icon === 'steps' && <path d="M3.5 8.2l2.6 2.6 6.4-6.4" />}
    </svg>
  );
}

/**
 * tesla.com home's "media + content row" ("Find Your Charge"): a rounded media block across the content width,
 * then a row with the title, subtitle and controls on the left and big stats with small round icons on the right.
 */
export function MediaRow({ id, title, sub, media, controls, caption, note, stats, className = '', sectionRef }: Props) {
  return (
    <section id={id} className={`mrow section ${className}`.trim()} ref={sectionRef} aria-labelledby={`${id}-title`}>
      <div className="wrap">
        <div className="mrow__media">
          <div className="mrow__stage">{media}</div>
        </div>

        <div className="mrow__row">
          <div className="mrow__copy">
            <h2 id={`${id}-title`} className="mrow__title">
              {title}
            </h2>
            <p className="mrow__sub">{sub}</p>
            <div className="mrow__controls">{controls}</div>
            {caption ? (
              <p className="mrow__caption" aria-live="polite">
                {caption}
              </p>
            ) : null}
            {note ? <p className="mrow__note">{note}</p> : null}
          </div>

          <ul className="mrow__stats">
            {stats.map((s) => (
              <li className="mrow__stat" key={s.label}>
                <span className="mrow__value">
                  {s.value}
                  {s.unit ? <span className="mrow__unit">{s.unit}</span> : null}
                </span>
                <span className="mrow__label">
                  <span className="mrow__icon">
                    <Glyph icon={s.icon} />
                  </span>
                  {s.label}
                </span>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </section>
  );
}
