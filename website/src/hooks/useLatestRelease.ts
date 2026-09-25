import { useEffect, useState } from 'react';
import { REPO, REPO_URL } from '../lib/links';

export type LatestRelease =
  | { state: 'loading'; href: string }
  | { state: 'ready'; href: string; version: string; sizeMB: number; pageUrl: string }
  | { state: 'none'; href: string };

type GhAsset = { name: string; browser_download_url: string; size: number };
type GhRelease = { tag_name: string; html_url: string; assets: GhAsset[] };

const KEY = `dashcast:release:${REPO}`;
const TTL = 10 * 60 * 1000;

function readCache(): LatestRelease | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    if (!raw) return null;
    const { at, value } = JSON.parse(raw) as { at: number; value: LatestRelease };
    return Date.now() - at < TTL ? value : null;
  } catch {
    return null;
  }
}

function writeCache(value: LatestRelease) {
  try {
    sessionStorage.setItem(KEY, JSON.stringify({ at: Date.now(), value }));
  } catch {
    /* storage unavailable (private mode, blocked site data) */
  }
}

/** Latest GitHub release of dw2lam/Dashcast: its .dmg when there is one, otherwise the repository page. */
export function useLatestRelease(): LatestRelease {
  const [release, setRelease] = useState<LatestRelease>(() => readCache() ?? { state: 'loading', href: REPO_URL });

  useEffect(() => {
    if (release.state !== 'loading') return;
    const ctrl = new AbortController();
    // The list (not /releases/latest) answers 200 with [] before the first release, so no console 404.
    fetch(`https://api.github.com/repos/${REPO}/releases?per_page=1`, {
      headers: { Accept: 'application/vnd.github+json' },
      signal: ctrl.signal,
    })
      .then((r) => (r.ok ? (r.json() as Promise<GhRelease[]>) : null))
      .then((list) => {
        const rel = list && list.length ? list[0] : null;
        const dmg = rel && rel.assets.find((a) => /\.dmg$/i.test(a.name));
        const value: LatestRelease =
          rel && dmg
            ? {
                state: 'ready',
                href: dmg.browser_download_url,
                version: rel.tag_name.replace(/^v/i, ''),
                sizeMB: Math.round((dmg.size / 1048576) * 10) / 10,
                pageUrl: rel.html_url,
              }
            : { state: 'none', href: REPO_URL };
        writeCache(value);
        setRelease(value);
      })
      .catch((e: unknown) => {
        if ((e as Error).name !== 'AbortError') setRelease({ state: 'none', href: REPO_URL });
      });
    return () => ctrl.abort();
  }, [release.state]);

  return release;
}
