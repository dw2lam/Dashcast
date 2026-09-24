import { useEffect, useRef } from 'react';
import { Photo } from '../ui/Photo';
import { Mark } from '../ui/Wordmark';
import { useLatestRelease } from '../hooks/useLatestRelease';
import { gsap, ease, prefersReducedMotion } from '../lib/motion';
import { REPO_URL } from '../lib/links';
import './Download.css';

export function Download() {
  const root = useRef<HTMLElement>(null);
  const release = useLatestRelease();
  const ready = release.state === 'ready';

  useEffect(() => {
    const el = root.current;
    if (!el || prefersReducedMotion()) return;
    const ctx = gsap.context(() => {
      gsap.fromTo('.photo img', { scale: 1.12 }, { scale: 1, ease: 'none', scrollTrigger: { trigger: el, start: 'top bottom', end: 'bottom bottom', scrub: true } });
      gsap
        .timeline({ scrollTrigger: { trigger: el, start: 'top 60%', once: true } })
        .fromTo('.download__mark', { y: 30, opacity: 0 }, { y: 0, opacity: 1, duration: 1, ease: ease.mktg }, 0)
        .fromTo('.download__title', { y: 100, opacity: 0 }, { y: 0, opacity: 1, duration: 1.5, ease: ease.mktg }, 0.05)
        .fromTo('.download__sub, .download__ctas, .download__meta', { y: 30, opacity: 0 }, { y: 0, opacity: 1, duration: 1, stagger: 0.08, ease: ease.mktg }, 0.2);
    }, el);
    return () => ctx.revert();
  }, []);

  return (
    <section id="download" className="download section on-dark" ref={root} aria-labelledby="download-title">
      <Photo className="download__photo" name="parked" alt="A car parked at dusk" tone="#1f2120" position="42% 0%" portraitPosition="50% 0%" />
      <div className="download__scrim" aria-hidden="true" />
      <div className="download__content">
        <span className="download__mark" aria-hidden="true">
          <Mark size={30} />
        </span>
        <h2 id="download-title" className="t-section download__title">
          Dashcast for Mac
        </h2>
        <p className="t-sub download__sub">Free and open source.</p>
        <div className="btn-row download__ctas">
          {ready ? (
            <>
              <a className="btn btn--primary" href={release.href}>
                Download for Mac
              </a>
              <a className="btn btn--light" href={REPO_URL} target="_blank" rel="noreferrer">
                View on GitHub
              </a>
            </>
          ) : (
            <a className="btn btn--primary" href={REPO_URL} target="_blank" rel="noreferrer">
              Get it on GitHub
            </a>
          )}
        </div>
        <p className="download__meta">
          {ready ? (
            <>
              Version {release.version} · {release.sizeMB} MB · macOS 15 or later · Apple silicon
            </>
          ) : (
            <>macOS 15 or later · Apple silicon · Version 0.0.1 · Signed builds land on GitHub Releases</>
          )}
        </p>
      </div>
    </section>
  );
}
