import { Photo } from '../ui/Photo';
import { useLatestRelease } from '../hooks/useLatestRelease';
import { APP_VERSION, AUTHOR_URL, DONATE_URL, REPO_URL } from '../lib/links';
import './Closing.css';

const ext = { target: '_blank', rel: 'noopener' } as const;

/**
 * The close: tesla.com home's grey tile pair ("Current Offers | Inventory"), Download and Support side by side,
 * then the site footer on white (one hairline row, like David's OpenHue / NotchTune footers).
 */
export function Closing() {
  const release = useLatestRelease();
  const ready = release.state === 'ready';
  const version = ready ? release.version : APP_VERSION;

  return (
    <div className="closing">
      <section id="download" className="closing__download section" aria-labelledby="download-title">
        <div className="wrap closing__tiles">
          <article className="ctile ctile--app">
            <div className="ctile__copy">
              <h2 id="download-title" className="ctile__title">
                Dashcast for Mac
              </h2>
              <p className="ctile__sub">Free and open source. macOS 15 or later on Apple silicon.</p>
              <div className="ctile__ctas">
                {ready ? (
                  <a className="btn btn--light" href={release.href}>
                    Download for Mac
                  </a>
                ) : (
                  <a className="btn btn--light" href={REPO_URL} {...ext}>
                    Get it on GitHub
                  </a>
                )}
                {ready ? (
                  <a className="btn btn--light" href={REPO_URL} {...ext}>
                    View on GitHub
                  </a>
                ) : null}
              </div>
              <p className="ctile__meta">
                v{version}
                {ready ? <> · {release.sizeMB} MB</> : null}
              </p>
            </div>
            <div className="ctile__media ctile__media--icon">
              <img src="/icon-512.png" width="200" height="200" alt="The Dashcast app icon" loading="lazy" decoding="async" />
            </div>
          </article>

          <article className="ctile ctile--support">
            <div className="ctile__copy">
              <h2 className="ctile__title">Support Dashcast</h2>
              <p className="ctile__sub">No ads, no subscription. Donations keep the updates coming.</p>
              <div className="ctile__ctas">
                <a className="btn btn--light" href={DONATE_URL} {...ext}>
                  Donate
                </a>
              </div>
            </div>
            <div className="ctile__media ctile__media--photo">
              <Photo name="charge" alt="Teslas charging at a Supercharger at night" tone="#171a20" position="50% 78%" landscapeOnly />
            </div>
          </article>
        </div>
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
