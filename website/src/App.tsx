import { Nav } from './sections/Nav';
import { Hero } from './sections/Hero';
import { Features } from './sections/Features';
import { Demo } from './sections/Demo';
import { Touch } from './sections/Touch';
import { Office } from './sections/Office';
import { Connect } from './sections/Connect';
import { Tech } from './sections/Tech';
import { Compare } from './sections/Compare';
import { Faq } from './sections/Faq';
import { Closing } from './sections/Closing';
import { Showcase } from './showcase';

// Every section is one of tesla.com's templates (DESIGN.md, "Template catalogue"). The demo and the Mac app are
// a matched pair, back to back. The site lead owns the section chrome; demo/* supplies the live car screen.
export default function App() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Features />
        <Demo />
        <Showcase />
        <Touch />
        <Office />
        <Connect />
        <Tech />
        <Compare />
        <Faq />
      </main>
      <Closing />
    </>
  );
}
