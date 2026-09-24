import { Nav } from './sections/Nav';
import { Hero } from './sections/Hero';
import { Extend } from './sections/Extend';
import { Touch } from './sections/Touch';
import { Feature } from './sections/Highlights';
import { Connect } from './sections/Connect';
import { Tech } from './sections/Tech';
import { Compare } from './sections/Compare';
import { Faq } from './sections/Faq';
import { Download } from './sections/Download';
import { Footer } from './sections/Footer';
import { DemoSection } from './demo';
import { Showcase } from './showcase';

// Section order: tesla.com's rhythm of full-bleed media broken up by white sections.
// Owners: sections/* = site lead, demo/* = Tesla demo, showcase/* = app screenshots.
export default function App() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Extend />
        <DemoSection />
        <Touch />
        <Feature id="sound" />
        <Showcase />
        <Feature id="mcu" />
        <Connect />
        <Tech />
        <Compare />
        <Faq />
        <Download />
      </main>
      {/* The demo section carries the parked/charging/passenger line, so the footer doesn't repeat it. */}
      <Footer safetyLine={false} />
    </>
  );
}
