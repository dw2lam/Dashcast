import React from 'react';
import ReactDOM from 'react-dom/client';
import '../../../src/styles/tokens.css';
import '../../../src/styles/global.css';
import { CabinScreen, DemoSection } from '../../../src/demo';
import { DemoScreen } from '../../../src/demo/screen';

const q = new URLSearchParams(location.search);
const only = q.get('only');

function Panel() {
  const ref = React.useRef<HTMLDivElement>(null);
  React.useEffect(() => {
    const s = new DemoScreen({
      display: (q.get('display') as any) || 'extend',
      tier: (q.get('tier') as any) || 'mcu3',
      stats: q.has('stats'),
    });
    ref.current!.appendChild(s.el);
    s.play();
    (window as any).__screen = s;
    return () => s.destroy();
  }, []);
  return <div ref={ref} style={{ position: 'relative', width: 1920, height: 1200, overflow: 'hidden' }} />;
}

function Harness() {
  if (q.has('panel')) return <Panel />;
  return (
    <main>
      {only !== 'demo' && (
        <div className="hero">
          <CabinScreen autoplay={!q.has('still')} interactive={q.has('touch')} />
        </div>
      )}
      {only !== 'hero' && <DemoSection />}
    </main>
  );
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <Harness />
  </React.StrictMode>,
);
(window as any).__gsap = import('gsap');
