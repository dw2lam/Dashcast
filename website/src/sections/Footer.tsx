import { AUTHOR_URL, DONATE_URL, REPO_URL } from '../lib/links';
import './Footer.css';

export function Footer({ safetyLine = true }: { safetyLine?: boolean }) {
  return (
    <footer className="footer">
      <ul className="footer__links">
        <li>
          <a href={AUTHOR_URL}>Dashcast © 2026 David Lam</a>
        </li>
        <li>
          <a href={REPO_URL} target="_blank" rel="noreferrer">
            GitHub
          </a>
        </li>
        <li>
          <a href={AUTHOR_URL}>davidlam.online</a>
        </li>
        <li>
          <a href={DONATE_URL} target="_blank" rel="noopener">
            Donate
          </a>
        </li>
      </ul>
      <p className="footer__fine">
        {safetyLine && <>For use while parked, charging or as a passenger. </>}
        Not affiliated with Tesla, Inc.
      </p>
    </footer>
  );
}
