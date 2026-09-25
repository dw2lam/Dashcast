import { Photo } from '../ui/Photo';
import './Band.css';

/** A quiet full-bleed photo break (tesla.com's photo section): one line near the top, no chrome, no motion. */
export function Band() {
  return (
    <section className="band on-dark" aria-labelledby="band-title">
      <Photo className="band__photo" name="mcu" alt="A Tesla Model 3 cabin and its centre screen" tone="#000000" position="50% 20%" portraitPosition="50% 20%" />
      <div className="band__scrim" aria-hidden="true" />
      <h2 id="band-title" className="t-section band__title">
        Nothing to install in the car.
      </h2>
    </section>
  );
}
