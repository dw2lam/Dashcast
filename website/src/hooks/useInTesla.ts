import { useEffect, useState } from 'react';

/** True when the page is open in a Tesla's own browser (its user agent carries a "Tesla/<firmware>" token). */
export function useInTesla() {
  const [inTesla, setInTesla] = useState(false);
  useEffect(() => {
    const ua = navigator.userAgent;
    setInTesla(/\bTesla\/\S+/.test(ua) || /[?&]tesla=1\b/.test(location.search));
  }, []);
  return inTesla;
}
