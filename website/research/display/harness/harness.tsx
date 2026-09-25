import React from 'react';
import ReactDOM from 'react-dom/client';
import '../../../src/styles/tokens.css';
import '../../../src/styles/global.css';
import { CabinScreen, DemoSection, DemoStage, McuVisual, SoundVisual } from '../../../src/demo';
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

function Vis() {
  const w = Number(q.get('w') || 634);
  const h = Number(q.get('h') || 508);
  const V = q.get('vis') === 'mcu' ? McuVisual : SoundVisual;
  return (
    <div style={{ padding: 20, background: '#f4f4f4', minHeight: '100vh', boxSizing: 'border-box' }}>
      <div id="card" style={{ position: 'relative', width: w, height: h, borderRadius: 8, overflow: 'hidden' }}>
        <V />
      </div>
    </div>
  );
}

function StageBox() {
  const w = Number(q.get('w') || 1080);
  const h = Number(q.get('h') || 675);
  const [display, setDisplay] = React.useState<'extend' | 'mirror'>((q.get('display') as any) || 'extend');
  const [tier, setTier] = React.useState<'mcu2' | 'mcu3'>((q.get('tier') as any) || 'mcu2');
  (window as any).__stageProps = { setDisplay, setTier };
  return (
    <div style={{ padding: 20, background: '#000', minHeight: '100vh', boxSizing: 'border-box' }}>
      <div id="card" style={{ position: 'relative', width: w, height: h }}>
        <DemoStage display={display} tier={tier} stats={q.has('stats')} />
      </div>
    </div>
  );
}

function Harness() {
  if (q.has('stage')) return <StageBox />;
  if (q.has('vis')) return <Vis />;
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
