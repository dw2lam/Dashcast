import { Nav } from './sections/Nav';
import { Hero } from './sections/Hero';
import { Highlights } from './sections/Highlights';
import { Connect } from './sections/Connect';
import { Tech } from './sections/Tech';
import { Download } from './sections/Download';
import { Footer } from './sections/Footer';
import { DemoSection } from './demo';
import { Showcase } from './showcase';

// Section order. Owners: sections/* = site lead, demo/* = Tesla demo, showcase/* = app screenshots.
export default function App() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <DemoSection />
        <Highlights />
        <Showcase />
        <Connect />
        <Tech />
        <Download />
      </main>
      {/* The demo section carries the parked/charging/passenger line, so the footer doesn't repeat it. */}
      <Footer safetyLine={false} />
    </>
  );
}
