import { useEffect, useId, useRef, useState } from 'react';
import { revealWithin, prefersReducedMotion } from '../lib/motion';
import { CAR_ADDRESS } from '../lib/links';
import './Faq.css';

const FAQS: { q: string; a: string }[] = [
  { q: 'Does anything get installed in my Tesla?', a: 'No. Dashcast runs in the car’s own web browser.' },
  {
    q: 'Which Teslas work?',
    a: 'Teslas with the in-car browser. Quality follows how fast the car’s computer decodes: 720p30 on Intel Atom (MCU2), up to 60 fps on AMD Ryzen (MCU3).',
  },
  {
    q: 'Do I need internet?',
    a: 'No. The Mac answers the car’s DNS and its connectivity check. Plugging an iPhone into the Mac over USB for internet is optional.',
  },
  {
    q: 'Why won’t my car open my Mac’s normal IP address?',
    a: `The Tesla browser blocks private addresses (192.168.x, 10.x, 172.16–31.x). Dashcast serves from ${CAR_ADDRESS} instead.`,
  },
  {
    q: 'Can my iPhone’s hotspot connect both?',
    a: 'No. Since iOS 18, devices on a hotspot can’t reach each other. Use Mac as Hotspot (recommended) or a travel router.',
  },
  { q: 'Does sound play through the car?', a: 'Yes. The first tap turns it on, and Cinema mode keeps lips in sync.' },
  {
    q: 'Secure or Compatibility mode?',
    a: 'Compatibility needs no setup and streams over WebRTC. Secure uses your own domain and a free Let’s Encrypt certificate to unlock WebCodecs, the lowest-latency path.',
  },
  { q: 'What does my Mac need?', a: 'macOS 15 or later on Apple silicon, plus the Screen Recording and Accessibility permissions.' },
  { q: 'Is it free?', a: 'Yes. It’s open source under the MIT license.' },
  { q: 'Can I use it while driving?', a: 'No. Dashcast is for when you’re parked or charging, or for a passenger.' },
];

function Chevron() {
  return (
    <svg className="faq__chevron" width="30" height="30" viewBox="0 0 30 30" aria-hidden="true" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12.5 9.5l5.5 5.5-5.5 5.5" />
    </svg>
  );
}

function Item({ q, a }: { q: string; a: string }) {
  const id = useId().replace(/:/g, '');
  const [open, setOpen] = useState(false);
  const panel = useRef<HTMLDivElement>(null);
  const first = useRef(true);

  useEffect(() => {
    const el = panel.current;
    if (!el) return;
    if (first.current) {
      first.current = false;
      return;
    }
    const done = () => {
      el.style.height = open ? 'auto' : '0px';
      if (!open) el.hidden = true;
    };
    if (prefersReducedMotion()) {
      el.hidden = !open;
      el.style.height = open ? 'auto' : '0px';
      return;
    }
    if (open) {
      el.hidden = false;
      el.style.height = '0px';
      void el.offsetHeight;
      el.style.height = `${el.scrollHeight}px`;
    } else {
      el.style.height = `${el.scrollHeight}px`;
      void el.offsetHeight;
      el.style.height = '0px';
    }
    const t = window.setTimeout(done, 520);
    return () => window.clearTimeout(t);
  }, [open]);

  return (
    <li className={`faq__item${open ? ' is-open' : ''}`}>
      <h3 className="faq__q">
        <button type="button" id={`q-${id}`} className="faq__btn" aria-expanded={open} aria-controls={`a-${id}`} onClick={() => setOpen((o) => !o)}>
          <Chevron />
          <span className="faq__title">{q}</span>
        </button>
      </h3>
      <div className="faq__panel" id={`a-${id}`} role="region" aria-labelledby={`q-${id}`} ref={panel} hidden style={{ height: 0 }}>
        <p className="faq__a">{a}</p>
      </div>
    </li>
  );
}

/** tesla.com support FAQ accordion: chevron left of the question, no dividers, several answers open at once. */
export function Faq() {
  const root = useRef<HTMLElement>(null);
  useEffect(() => (root.current ? revealWithin(root.current) : undefined), []);

  return (
    <section id="faq" className="faq section" ref={root} aria-labelledby="faq-title">
      <div className="faq__wrap">
        <h2 id="faq-title" className="faq__heading" data-reveal="small">
          Frequently Asked Questions
        </h2>
        <ul className="faq__list" data-reveal="small" data-reveal-delay="0.1">
          {FAQS.map((f) => (
            <Item key={f.q} q={f.q} a={f.a} />
          ))}
        </ul>
      </div>
    </section>
  );
}
