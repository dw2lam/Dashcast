import { useCallback, useEffect, useLayoutEffect, useRef, type KeyboardEvent, type ReactNode } from 'react';
import './Segmented.css';

export type SegmentedItem<T extends string> = {
  id: T;
  label: ReactNode;
  /** Accessible name when the label is not plain text. */
  ariaLabel?: string;
};

type Props<T extends string> = {
  items: SegmentedItem<T>[];
  value: T;
  onChange: (id: T) => void;
  /** Accessible name of the whole control. */
  label: string;
  /** "tablist" when it switches a panel (pass `controls`), "radiogroup" when it picks a setting. */
  semantics?: 'tablist' | 'radiogroup';
  /** "dark" for black sections. */
  tone?: 'light' | 'dark';
  /** Stretch to the container width with equal segments (phones). */
  fill?: boolean;
  /** Tablist only: id of the panel the tabs switch. */
  controls?: string;
  /** Tablist only: each tab gets the id `${idPrefix}-${item.id}`, for the panel's aria-labelledby. */
  idPrefix?: string;
  className?: string;
};

/**
 * tesla.com's segmented control: a 40px #f4f4f4 track (4px radius) whose active segment is a white pill that
 * slides between options (.5s cubic-bezier(.75,0,0,1), the TDS animated backdrop). The dark tone is the same
 * control for black sections. Arrow keys, Home and End move the selection; one segment is in the tab order.
 */
export function Segmented<T extends string>({
  items,
  value,
  onChange,
  label,
  semantics = 'radiogroup',
  tone = 'light',
  fill = false,
  controls,
  idPrefix,
  className = '',
}: Props<T>) {
  const trackRef = useRef<HTMLDivElement>(null);
  const pillRef = useRef<HTMLSpanElement>(null);
  const placed = useRef(false);
  const isTabs = semantics === 'tablist';

  const movePill = useCallback((animate: boolean) => {
    const track = trackRef.current;
    const pill = pillRef.current;
    const btn = track?.querySelector<HTMLElement>('[data-on="true"]');
    if (!track || !pill || !btn) return;
    if (!animate) pill.style.transition = 'none';
    pill.style.width = `${btn.offsetWidth}px`;
    pill.style.transform = `translateX(${btn.offsetLeft}px)`;
    pill.style.opacity = '1';
    if (!animate) {
      void pill.offsetWidth;
      pill.style.transition = '';
    }
  }, []);

  useLayoutEffect(() => {
    movePill(placed.current);
    placed.current = true;
  }, [value, movePill]);

  useEffect(() => {
    const track = trackRef.current;
    if (!track) return;
    const ro = new ResizeObserver(() => movePill(false));
    ro.observe(track);
    document.fonts?.ready.then(() => movePill(false));
    return () => ro.disconnect();
  }, [movePill]);

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const i = items.findIndex((it) => it.id === value);
    let next = -1;
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') next = (i + 1) % items.length;
    else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') next = (i - 1 + items.length) % items.length;
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = items.length - 1;
    if (next < 0) return;
    e.preventDefault();
    onChange(items[next].id);
    trackRef.current?.querySelectorAll<HTMLElement>('.ui-seg__opt')[next]?.focus();
  };

  return (
    <div
      ref={trackRef}
      className={`ui-seg ui-seg--${tone}${fill ? ' ui-seg--fill' : ''} ${className}`.trim()}
      role={semantics}
      aria-label={label}
      onKeyDown={onKeyDown}
    >
      <span className="ui-seg__pill" ref={pillRef} aria-hidden="true" />
      {items.map((it) => {
        const on = it.id === value;
        return (
          <button
            key={it.id}
            type="button"
            className="ui-seg__opt"
            data-on={on}
            role={isTabs ? 'tab' : 'radio'}
            id={isTabs && idPrefix ? `${idPrefix}-${it.id}` : undefined}
            aria-selected={isTabs ? on : undefined}
            aria-checked={isTabs ? undefined : on}
            aria-controls={isTabs ? controls : undefined}
            aria-label={it.ariaLabel}
            tabIndex={on ? 0 : -1}
            onClick={() => onChange(it.id)}
          >
            {it.label}
          </button>
        );
      })}
    </div>
  );
}
