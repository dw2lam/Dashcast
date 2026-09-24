import { Nav } from './sections/Nav';
import { Hero } from './sections/Hero';
import { Features } from './sections/Features';
import { Touch } from './sections/Touch';
import { Band } from './sections/Band';
import { Office } from './sections/Office';
import { Connect } from './sections/Connect';
import { Tech } from './sections/Tech';
import { Compare } from './sections/Compare';
import { Faq } from './sections/Faq';
import { Closing } from './sections/Closing';
import { DemoSection } from './demo';
import { Showcase } from './showcase';

// Section order: tesla.com's rhythm, white sections broken up by black and full-bleed photo ones.
// Owners: sections/* = site lead, demo/* = Tesla demo, showcase/* = app screenshots.
export default function App() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Features />
        <DemoSection />
        <Touch />
        <Office />
        <Showcase />
        <Band />
        <Connect />
        <Tech />
        <Compare />
        <Faq />
      </main>
      {/* Download + footer share one photo; the demo section carries the parked/charging/passenger line. */}
      <Closing />
    </>
  );
}
