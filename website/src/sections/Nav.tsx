import { useCallback, useEffect, useRef, useState } from 'react';
import { Wordmark } from '../ui/Wordmark';
import { CloseIcon, GitHubIcon } from '../ui/icons';
import { REPO_URL } from '../lib/links';
import './Nav.css';

const LINKS = [
  { id: 'demo', label: 'Demo' },
  { id: 'app', label: 'App' },
  { id: 'connect', label: 'Connect' },
  { id: 'tech', label: 'Tech' },
  { id: 'faq', label: 'FAQ' },
  { id: 'download', label: 'Download' },
];

export function Nav() {
  const [active, setActive] = useState<string | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);
  const pillRef = useRef<HTMLSpanElement>(null);
  const hovering = useRef(false);

  useEffect(() => {
    const seen = new Map<string, boolean>();
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) seen.set(e.target.id, e.isIntersecting);
        const current = LINKS.find((l) => seen.get(l.id));
        setActive(current ? current.id : null);
      },
      { rootMargin: '-45% 0px -54% 0px' },
    );
    const observe = () => {
      for (const l of LINKS) {
        const el = document.getElementById(l.id);
        if (el) io.observe(el);
      }
    };
    observe();
    const retry = window.setTimeout(observe, 1500);
    return () => {
      window.clearTimeout(retry);
      io.disconnect();
    };
  }, []);

  const placePill = useCallback((target: HTMLElement | null) => {
    const pill = pillRef.current;
    const list = listRef.current;
    if (!pill || !list) return;
    if (!target) {
      pill.style.opacity = '0';
      return;
    }
    const lr = list.getBoundingClientRect();
    const tr = target.getBoundingClientRect();
    const wasHidden = pill.style.opacity !== '1';
    if (wasHidden) {
      pill.style.transition = 'none';
      pill.style.transform = `translateX(${tr.left - lr.left}px)`;
      pill.style.width = `${tr.width}px`;
      void pill.offsetWidth;
      pill.style.transition = '';
    } else {
      pill.style.transform = `translateX(${tr.left - lr.left}px)`;
      pill.style.width = `${tr.width}px`;
    }
    pill.style.opacity = '1';
  }, []);

  const restPill = useCallback(() => {
    const el = active ? listRef.current?.querySelector<HTMLElement>(`[data-id="${active}"]`) : null;
    placePill(el || null);
  }, [active, placePill]);

  useEffect(() => {
    if (!hovering.current) restPill();
  }, [restPill]);

  useEffect(() => {
    if (!menuOpen) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setMenuOpen(false);
    document.addEventListener('keydown', onKey);
    document.documentElement.style.overflow = 'hidden';
    return () => {
      document.removeEventListener('keydown', onKey);
      document.documentElement.style.overflow = '';
    };
  }, [menuOpen]);

  return (
    <>
      <header className="nav">
        <a className="nav__brand" href="#top" aria-label="Dashcast, back to top">
          <Wordmark />
        </a>

        <nav className="nav__center" aria-label="Sections">
          <div
            className="nav__links"
            ref={listRef}
            onPointerLeave={() => {
              hovering.current = false;
              restPill();
            }}
          >
            <span className="nav__pill" ref={pillRef} aria-hidden="true" />
            <ul>
            {LINKS.map((l) => (
              <li key={l.id}>
                <a
                  className={`nav__item${active === l.id ? ' is-active' : ''}`}
                  href={`#${l.id}`}
                  data-id={l.id}
                  onPointerEnter={(e) => {
                    hovering.current = true;
                    placePill(e.currentTarget);
                  }}
                  onFocus={(e) => placePill(e.currentTarget)}
                  onBlur={() => restPill()}
                >
                  {l.label}
                </a>
              </li>
            ))}
            </ul>
          </div>
        </nav>

        <div className="nav__end">
          <a className="nav__item nav__item--icon" href={REPO_URL} target="_blank" rel="noreferrer" aria-label="Dashcast on GitHub">
            <GitHubIcon />
          </a>
          <button
            className="nav__item nav__menu-btn"
            type="button"
            aria-expanded={menuOpen}
            aria-controls="site-menu"
            onClick={() => setMenuOpen(true)}
          >
            Menu
          </button>
        </div>
      </header>

      <div
        id="site-menu"
        className={`menu${menuOpen ? ' is-open' : ''}`}
        role="dialog"
        aria-modal="true"
        aria-label="Site menu"
        aria-hidden={!menuOpen}
      >
        <div className="menu__head">
          <button className="nav__item nav__item--icon menu__close" type="button" aria-label="Close menu" onClick={() => setMenuOpen(false)} tabIndex={menuOpen ? 0 : -1}>
            <CloseIcon />
          </button>
        </div>
        <ul className="menu__list">
          {LINKS.map((l, i) => (
            <li key={l.id} style={{ transitionDelay: menuOpen ? `${0.05 + i * 0.03}s` : '0s' }}>
              <a className="menu__item" href={`#${l.id}`} onClick={() => setMenuOpen(false)} tabIndex={menuOpen ? 0 : -1}>
                {l.label}
              </a>
            </li>
          ))}
          <li style={{ transitionDelay: menuOpen ? `${0.05 + LINKS.length * 0.03}s` : '0s' }}>
            <a className="menu__item" href={REPO_URL} target="_blank" rel="noreferrer" tabIndex={menuOpen ? 0 : -1}>
              GitHub
            </a>
          </li>
        </ul>
      </div>
    </>
  );
}
