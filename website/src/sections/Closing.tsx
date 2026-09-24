import { useEffect, useRef } from 'react';
import { Photo } from '../ui/Photo';
import { useLatestRelease } from '../hooks/useLatestRelease';
import { gsap, ease, prefersReducedMotion } from '../lib/motion';
import { APP_VERSION, AUTHOR_URL, DONATE_URL, REPO_URL } from '../lib/links';
import './Closing.css';

const ext = { target: '_blank', rel: 'noopener' } as const;

/**
 * The page's closing moment: Download over a night-time Supercharger, with the site footer on the same photo
 * (one hairline row, like David's OpenHue / NotchTune footers).
 */
export function Closing() {
  const root = useRef<HTMLDivElement>(null);
  const release = useLatestRelease();
  const ready = release.state === 'ready';
  const version = ready ? release.version : APP_VERSION;

  useEffect(() => {
    const el = root.current;
    if (!el || prefersReducedMotion()) return;
    const ctx = gsap.context(() => {
      gsap.fromTo('.photo img', { scale: 1.1 }, { scale: 1, ease: 'none', scrollTrigger: { trigger: el, start: 'top bottom', end: 'bottom bottom', scrub: true } });
      gsap
        .timeline({ scrollTrigger: { trigger: el, start: 'top 62%', once: true } })
        .fromTo('.closing__icon', { y: 30, opacity: 0 }, { y: 0, opacity: 1, duration: 1, ease: ease.mktg }, 0)
        .fromTo('.closing__title', { y: 60, opacity: 0 }, { y: 0, opacity: 1, duration: 1.2, ease: ease.mktg }, 0.05)
        .fromTo('.closing__sub, .closing__ctas, .closing__meta', { y: 24, opacity: 0 }, { y: 0, opacity: 1, duration: 0.9, stagger: 0.08, ease: ease.mktg }, 0.2);
    }, el);
    return () => ctx.revert();
  }, []);

  return (
    <div className="closing on-dark" ref={root}>
      <Photo className="closing__photo" name="charge" alt="Teslas charging at a Supercharger at night" tone="#08090b" position="60% 60%" portraitPosition="50% 60%" />
      <div className="closing__scrim" aria-hidden="true" />

      <section id="download" className="closing__download" aria-labelledby="download-title">
        <img className="closing__icon" src="/icon-192.png" width="72" height="72" alt="" decoding="async" />
        <h2 id="download-title" className="t-section closing__title">
          Dashcast for Mac
        </h2>
        <p className="t-sub closing__sub">Free and open source. Donations keep the updates coming.</p>
        <div className="btn-row closing__ctas">
          {ready ? (
            <a className="btn btn--primary" href={release.href}>
              Download for Mac
            </a>
          ) : (
            <a className="btn btn--primary" href={REPO_URL} {...ext}>
              Get it on GitHub
            </a>
          )}
          <a className="btn btn--light" href={DONATE_URL} {...ext}>
            Donate
          </a>
        </div>
        <p className="closing__meta">
          macOS 15 or later · Apple silicon · v{version}
          {ready ? <> · {release.sizeMB} MB</> : null}
        </p>
      </section>

      <footer className="foot">
        <div className="foot__row">
          <a className="foot__brand" href="#top" aria-label="Dashcast, back to top">
            <img className="foot__icon" src="/icon-192.png" width="28" height="28" alt="" loading="lazy" decoding="async" />
            <span className="foot__mark">Dashcast</span>
            <span className="foot__tag">Your Mac, on your Tesla&rsquo;s screen.</span>
          </a>
          <nav className="foot__links" aria-label="Footer">
            <a href={REPO_URL} {...ext}>
              GitHub
            </a>
            <a href={DONATE_URL} {...ext}>
              Donate
            </a>
            <a href={AUTHOR_URL} {...ext}>
              David Lam
            </a>
          </nav>
        </div>
        <p className="foot__legal">© 2026 David Lam · v{version} · Free and open source · Not affiliated with Tesla, Inc.</p>
      </footer>
    </div>
  );
}
