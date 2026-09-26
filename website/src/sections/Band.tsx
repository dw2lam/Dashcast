import { useEffect, useRef, useState } from 'react';
import { Photo } from '../ui/Photo';
import './Band.css';

/**
 * The office story's closing line, rendered inside #office: the cabin photo rises out of the section's black
 * (a long black-to-clear fade, no edge) and the line sits over that fade in the office heading's size and
 * column. The photo pushes in very slowly while it is on screen (CSS, Band.css). The bottom is a clean cut into
 * the white Connect section, as Tesla's photo sections do.
 */
export function Band() {
  const root = useRef<HTMLDivElement>(null);
  const [live, setLive] = useState(false);

  useEffect(() => {
    const el = root.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => setLive(e.isIntersecting));
    io.observe(el);
    return () => io.disconnect();
  }, []);

  return (
    <div className={`band${live ? ' is-live' : ''}`} ref={root}>
      <Photo className="band__photo" name="mcu" alt="A Tesla Model 3 cabin and its centre screen" tone="#000000" position="50% 30%" portraitPosition="50% 30%" />
      <div className="band__fade" aria-hidden="true" />
      <div className="wrap band__copy">
        <p className="t-section band__line">Nothing to install in the car.</p>
      </div>
    </div>
  );
}
