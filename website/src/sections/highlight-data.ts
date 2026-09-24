export type Stat = { value: string; unit?: string; label: string };

export type Highlight = {
  id: string;
  media: string;
  alt: string;
  title: string;
  sub: string;
  stats?: Stat[];
  theme: 'dark' | 'light';
  scrim?: 'strong' | 'heavy';
  tone: string;
  position?: string;
  portraitPosition?: string;
};

export const HIGHLIGHTS: Highlight[] = [
  {
    id: 'extend',
    media: 'extend',
    alt: 'A Tesla Model 3 centre screen glowing in a dark cabin',
    title: 'Extend or mirror',
    sub: 'A second display for your Mac, right on the dash.',
    stats: [
      { value: 'Extend', label: 'HiDPI, sized to the car' },
      { value: 'Mirror', label: 'The screen you’re on' },
    ],
    theme: 'dark',
    scrim: 'heavy',
    tone: '#292827',
    position: '50% 50%',
    portraitPosition: '50% 50%',
  },
  {
    id: 'touch',
    media: 'touch',
    alt: 'A hand tapping a Tesla Model 3 touchscreen',
    title: 'Touch is the mouse',
    sub: 'The car’s screen drives your Mac. Keyboard included.',
    stats: [
      { value: 'Tap', label: 'Click' },
      { value: 'Hold', label: 'Right-click' },
      { value: 'Two fingers', label: 'Scroll' },
    ],
    theme: 'dark',
    scrim: 'strong',
    tone: '#3f5153',
    position: '50% 50%',
    portraitPosition: '50% 50%',
  },
  {
    id: 'sound',
    media: 'sound',
    alt: 'A dark Tesla Model 3 cabin',
    title: 'Sound through the car',
    sub: 'Your Mac’s audio on the car’s speakers, in sync with the picture.',
    stats: [
      { value: '250', unit: 'ms', label: 'Cinema: lips in sync' },
      { value: '60', unit: 'ms', label: 'Interactive' },
      { value: 'Auto', label: 'Switches for you' },
    ],
    theme: 'dark',
    tone: '#161d23',
  },
  {
    id: 'mcu',
    media: 'mcu',
    alt: 'A Tesla dashboard and centre screen',
    title: 'Built for MCU2 and MCU3',
    sub: 'Quality is picked from how fast your car decodes, and tuned live.',
    stats: [
      { value: '720p', unit: '30', label: 'MCU2 · Intel Atom' },
      { value: '60', unit: 'fps', label: 'MCU3 · AMD Ryzen' },
    ],
    theme: 'dark',
    scrim: 'strong',
    tone: '#333a3b',
    position: '50% 0%',
    portraitPosition: '50% 0%',
  },
];
