import { useEffect } from 'react';
import { Photo } from '../ui/Photo';
import { useLatestRelease } from '../hooks/useLatestRelease';
import { installEndSnap } from '../lib/endSnap';
import { APP_VERSION, AUTHOR_URL, DONATE_URL, REPO_URL } from '../lib/links';
import './Closing.css';

const ext = { target: '_blank', rel: 'noopener' } as const;

/**
 * The finale, the way tesla.com's model pages end (/modely "Model Y · Design Yours": a full-viewport photo, a 64px
 * title about 100px down it, one CTA 24px under): the Supercharger at night, "Dashcast for Mac", Download and
 * GitHub, a quiet meta line and Donate, and the site footer on the same photo behind a hairline.
 */
export function Closing() {
  const release = useLatestRelease();
  const ready = release.state === 'ready';
  const version = ready ? release.version : APP_VERSION;
  useEffect(installEndSnap, []);

  return (
    <div className="closing on-dark">
      <Photo className="closing__photo" name="charge" alt="Teslas charging at a Supercharger at night" tone="#000000" position="60% 62%" portraitPosition="58% 62%" />
      <div className="closing__scrim" aria-hidden="true" />

      <section id="download" className="closing__download" aria-labelledby="download-title">
        <img className="closing__icon" src="/icon-192.png" width="72" height="72" alt="" decoding="async" />
        <h2 id="download-title" className="t-hero closing__title">
          Dashcast for Mac
        </h2>
        <p className="t-sub closing__sub">Your Mac, on your Tesla&rsquo;s screen. Free and open source.</p>
        <div className="btn-row closing__ctas">
          <a className="btn btn--primary" href={release.href} {...(ready ? {} : ext)}>
            Download for Mac
          </a>
          <a className="btn btn--light" href={REPO_URL} {...ext}>
            View on GitHub
          </a>
        </div>
        <p className="closing__meta">
          macOS 15 or later · Apple silicon · v{version}
          {ready ? <> · {release.sizeMB} MB</> : null}
        </p>
        <a className="closing__donate" href={DONATE_URL} {...ext}>
          Donate to support Dashcast
        </a>
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
