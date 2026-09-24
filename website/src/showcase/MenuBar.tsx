import type { LayoutName } from './data';

/** Dashcast's status item: a car seen from the front, with the cast waves above it. */
function CarGlyph() {
  return (
    <svg className="sc__glyph sc__glyph--car" viewBox="0 0 20 16" aria-hidden="true">
      <path d="M6.2 4.6a5.4 5.4 0 0 1 7.6 0M4.3 2.7a8 8 0 0 1 11.4 0" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
      <path
        d="M5.6 8.2 6.6 6.4c.2-.4.6-.6 1-.6h4.8c.4 0 .8.2 1 .6l1 1.8c.9.3 1.5 1.1 1.5 2v2.3c0 .4-.3.7-.7.7h-.9v.8c0 .4-.3.7-.7.7h-.6c-.4 0-.7-.3-.7-.7v-.8H7.7v.8c0 .4-.3.7-.7.7h-.6c-.4 0-.7-.3-.7-.7v-.8h-.9c-.4 0-.7-.3-.7-.7v-2.3c0-.9.6-1.7 1.5-2Zm1.4-.1h6l-.7-1.2H7.7L7 8.1Zm-.6 3.2a.8.8 0 1 0 0-1.6.8.8 0 0 0 0 1.6Zm7.2 0a.8.8 0 1 0 0-1.6.8.8 0 0 0 0 1.6Z"
        fill="currentColor"
      />
    </svg>
  );
}

function WifiGlyph() {
  return (
    <svg className="sc__glyph" viewBox="0 0 18 14" aria-hidden="true">
      <path d="M9 12.2 11 10a2.8 2.8 0 0 0-4 0l2 2.2Z" fill="currentColor" />
      <path d="M4.9 7.8a5.8 5.8 0 0 1 8.2 0M2.5 5.3a9.2 9.2 0 0 1 13 0" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  );
}

function BatteryGlyph() {
  return (
    <svg className="sc__glyph sc__glyph--battery" viewBox="0 0 26 13" aria-hidden="true">
      <rect x="0.75" y="0.75" width="21.5" height="11.5" rx="3.2" fill="none" stroke="currentColor" strokeOpacity="0.5" strokeWidth="1.1" />
      <rect x="2.4" y="2.4" width="15.5" height="8.2" rx="1.8" fill="currentColor" />
      <path d="M23.8 4.6c.9.3 1.3.9 1.3 1.9s-.4 1.6-1.3 1.9V4.6Z" fill="currentColor" fillOpacity="0.5" />
    </svg>
  );
}

/**
 * The stage's menu bar, drawn as macOS 26 draws it over a wallpaper: no bar, just the items.
 * Sized in points through the stage's --u, like the windows.
 */
export function MenuBar({ layout, open }: { layout: LayoutName; open: boolean }) {
  const wide = layout === 'wide';
  return (
    <div className="sc__bar" aria-hidden="true">
      <div className="sc__menus">
        <span className="sc__menu sc__menu--app">Dashcast</span>
        {wide && (
          <>
            <span className="sc__menu">File</span>
            <span className="sc__menu">Edit</span>
            <span className="sc__menu">Cast</span>
            <span className="sc__menu">Window</span>
            <span className="sc__menu">Help</span>
          </>
        )}
      </div>
      <div className="sc__extras">
        <span className={`sc__status${open ? ' is-open' : ''}`}>
          <CarGlyph />
        </span>
        <span className="sc__extra">
          <WifiGlyph />
        </span>
        {wide && (
          <span className="sc__extra">
            <BatteryGlyph />
          </span>
        )}
        <span className="sc__clock">{wide ? 'Wed Sep 24  9:41 AM' : '9:41'}</span>
      </div>
    </div>
  );
}
