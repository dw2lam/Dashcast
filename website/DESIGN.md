# Dashcast site: design system

The site copies **tesla.com's** own design system (TDS). The values were measured live on 2026-09-24; the raw data is in `research/tesla-web/NOTES.md`. All tokens live in `src/styles/tokens.css`. Use the variables and never hard-code these values.

## Principles (Tesla's, applied)
1. **One idea per full-viewport section.** Use a real photo, full bleed. The title is centred at the top, the stats run along the bottom, and nothing else goes on the photo.
2. **Few words.**
   - A title (2–5 words), one subtitle line, and at most two CTAs.
   - Detail goes in label/value stats, never in paragraphs.
3. **One accent.**
   - Tesla blue `#3e6ae1` is only for the primary CTA.
   - The Dashcast gradient (`#0872fe → #15abfe → #18d3fd`) only appears on the mark, the diagram signals and the one IP address.
4. **Flat and quiet.**
   - All radii are 4px.
   - Lines are 1px hairlines.
   - There's no glass shine. The only blur is the 16px behind nav pills.
5. **Restrained motion.**
   - Two reveal presets and three curves.
   - Scrubbed zooms go on photos only.
   - Everything turns off under `prefers-reduced-motion`.

## Type
Tesla uses two proprietary faces, **Universal Sans Display** for titles and numbers and **Universal Sans Text** for UI and body. They're licensed to Tesla, so we never ship them.

**Helvetica** takes both roles (owner's call, 2026-09-24). The stack is `'Helvetica Neue', Helvetica, Arial, sans-serif`. Apple devices use their system copy, and Helvetica Neue has the Medium (500) that Tesla titles use; everything else falls back to Arial. No font files ship.
- **Display:** weight 500, tracking −0.01em.
- **Text:** 400/500.
- **Earlier stand-ins:** Inter Tight and Inter were matched against a pixel capture of tesla.com (`research/tesla-web/refs/tesla-type.png`). Both are free (SIL OFL), so switching back is a one-line token change in `tokens.css` plus the Google Fonts link.

### Scale (TDS `--tds-font-size-*`)

| token | size |
|---|---|
| 10 | 10/18 |
| 20 | 12/20 |
| 30 | 14/20 |
| 40 | 17/24 |
| 50 | 20/28 |
| 60 | 24/28 |
| 70 | 28/36 |
| 75 | 34/44 |
| 80 | 40/48 |
| 90 | 48/56 |
| 100 | 56/64 |
| 110 | 64/64 |

### Roles (responsive via the variables)

| Role | Desktop | Below 1200 | Phone (below 600) | Class |
|---|---|---|---|---|
| Hero title | 64/64 | 56/64 | 40/48 | `.t-hero` |
| Section title | 48/56 | 40/48 | 28/36 | `.t-section` |
| Block title | 28/36 | 28/36 | 28/36 | `.t-title` |
| Subtitle | 20/28 regular | 20/28 regular | 17/24 regular | `.t-sub` |
| Big stat | 64/64 + unit 28/36 + label 20/28 | 56/64 + unit 28/36 + label 20/28 | 34/44 + unit 20/28 + label 14/20 | `.stat` |
| Body, labels, buttons, nav | 14/20 Text | 14/20 Text | 14/20 Text | `.t-body`, `.t-label` |
| Footer | 12/20 Text 500 | 12/20 Text 500 | 12/20 Text 500 | — |

## Colour

| Token | Hex | Use |
|---|---|---|
| `--c-ink` | #171a20 | headings, nav, stat values |
| `--c-text` | #393c41 | body |
| `--c-text-low` | #5c5e62 | labels, footer |
| `--c-grey-70` | #f4f4f4 | tertiary button, tab track, diagram panel |
| `--c-grey-60` | #e2e3e3 | hairlines on white |
| `--c-grey-50` | #d0d1d2 | stat separators |
| `--c-blue` / `--c-blue-hover` | #3e6ae1 / #3457b1 | primary CTA only |
| `--c-hover` | 5% black | nav/footer hover pill |
| `--c-hover-dark` | 12% white | nav/footer hover pill on photos |
| Dark section | #000 bg, #fff values, #8e8e8e labels, 14% white hairlines | Tesla's specs table |
| `--grad-brand` | #0872fe → #15abfe → #18d3fd | the Dashcast mark, diagram signals, the IP |

## Components
- **Nav** (`sections/Nav`): tesla.com's home header as it is today.
  - A solid white 56px bar, `position: sticky; top: 0`, always visible, with no shadow and no hide-on-scroll. The hero starts below it.
  - Three columns: wordmark / centred anchor links (Demo · App · Connect · Tech · FAQ · Download) / GitHub icon.
  - Items are 32px tall (40px on touch screens and under 1280px), with 16px padding, a 4px radius, 14/500 ink.
  - One **backdrop pill** (5% black) slides between items: `transform` and `width` over 0.5s `--ease-slide`, with a separate 0.5s opacity fade. When you aren't hovering, it rests on the active section's link.
  - Below 900px the links collapse into a "Menu" pill. It opens a full-height white sheet with 56px rows, fading in over 0.5s `--ease`.
- **Buttons** (`.btn`):
  - 40px tall, 200px minimum width, padding 4px 24px, 3px transparent border, radius 4px, 14/500
  - background/colour transition .33s
  - variants: `--primary` (blue), `--light` (white on photos), `--secondary` (#f4f4f4 on white), `--dark`
  - below 600px, each button fills its grid column
  - `.btn-row` is a centred two-column grid
- **Stats** (`.stats > .stat`):
  - Tesla badge group: value, then unit (4px gap, baseline-aligned), then label
  - 1px separators between stats
  - on the hero and highlights the stats run along the bottom of the photo at 40/48, with 20/28 units and 14/20 labels
- **Photo** (`ui/Photo`):
  - `<picture>` with AVIF, then WebP
  - landscape `<name>-{960,1600,2400}` and portrait `<name>-p{750,1125}`
  - viewports at or narrower than 4:5 get the portrait crop
  - object-position comes from `--pos` / `--pos-portrait`
- **Tabs** (`.tabs` in Connect):
  - #f4f4f4 track with 4px padding
  - a white pill with a soft shadow slides under the active tab (.5s `--ease-slide`)
  - arrow keys move between tabs
- **Scrims:** Tesla's section start/end gradients, black to transparent from the top and the bottom, so white type stays legible on any photo.

## White sections (round 3)
These follow tesla.com today: full-bleed media sections are broken up by white sections built from Tesla's current patterns.
- **Split card** (`sections/Features`, `.split*`, in the `.srow` highlights row): Tesla's FSD block.
  - A #f4f4f4 card with an 8px radius and 48px page margins.
  - Copy on the left (40/48 title, 20/28 grey subtitle, 34/44 stat values with 14/20 labels, a dark button); photo flush right.
  - Below 900px the photo stacks on top.
- **Card carousel** (`sections/Touch`, `.cards*`, `.card*`, gestures only): "Meet Model Y".
  - A centred 48/56 header over 430×500 cards (8px radius) on a native `overflow-x: auto` track with scroll-snap. The track is padded to the 1200 content column, so the next card peeks in.
  - 40×40 prev/next controls on #f4f4f4 sit at the section edges, only on hover-capable screens of 900px and up. Each is hidden at its end.
  - Cards are dark with animated gesture art (`Gestures.tsx`, `.g-*`). Animation runs only while the section is on screen and never under reduced motion.
- **Compare** (`sections/Compare`, `.cmp*`): Tesla's /compare pattern.
  - A label column plus "Dashcast" and "Others" columns; 20/28 values with 14/20 notes; a blue check or grey dash.
  - Hairline rows so the six rows scan quickly.
  - Below 600px the label sits above both values and the two value columns stay side by side.
- **FAQ** (`sections/Faq`, `.faq*`): Tesla's support accordion.
  - A 774px column with a 40/48 heading; a 30px chevron left of each 14/20 question; no dividers.
  - The chevron rotates 90° and the question turns ink when open, with several open at once.
  - Buttons carry `aria-expanded` and `aria-controls` → `role="region"` panels, and closed panels are `hidden`.
  - The height animates over 0.5s with `--ease`; reduced motion snaps it. Buttons are at least 40px tall (Tesla's are 20px plus 24px spacing) for touch.

## Section order (round 4)
| # | Section | Surface | Notes |
|---|---|---|---|
| 1 | Hero | full-bleed (the demo's cabin composite) | |
| 2 | Highlights row | white | grey split cards Extend or mirror · Sound through the car · Built for MCU2 and MCU3, ~88% wide with the next peeking, arrows and dots |
| 3 | Demo | black | |
| 4 | Touch is the mouse | white feature-card carousel | Tap · Drag · Two fingers · Hold · Keyboard |
| 5 | Your office, anywhere | graphite | our own animated line drawing plus three steps |
| 6 | The Mac app showcase | white | |
| 7 | Band: "Nothing to install in the car." | full-bleed | MCU interior photo |
| 8 | Connect | white | |
| 9 | Under the hood | black | |
| 10 | Compare | white | |
| 11 | FAQ | white | |
| 12 | Closing | full-bleed | Download plus the footer on one photo (Teslas at a Supercharger at night) |

There are never more than two white sections in a row. Sound and MCU live in the section-2 highlights row as split cards, next to Extend.

## Carousel input (`hooks/useCarousel.ts`, shared by the highlights row and the gesture carousel)
The track is a native `overflow-x: auto` scroller (`.snap-track` in global.css). The JS never blocks vertical page scroll or the browser's own gestures.
- **Trackpad and shift+wheel:** native.
  - Shift+wheel is converted to horizontal scroll only when the OS hasn't already done that.
  - On mouse/trackpad screens CSS snap is off. Once a gesture stops (160ms with no scroll events), the hook settles on a card in the direction of travel. Any intentional swipe (24px or more) pages to the next card. It does nothing if the browser has already snapped to a card.
- **Mouse drag:**
  - Pointer events with grab/grabbing cursors. Pointer capture starts after 5px of movement, so plain clicks still reach their targets.
  - Velocity-projected momentum, then a glide to the nearest card with `--ease-mktg`.
  - No text selection while dragging, and the click that ends a drag is swallowed.
- **Touch:** native, with CSS `scroll-snap-type: x mandatory` on coarse pointers, so the browser's flick velocity picks the card.
- **Keyboard:** the focusable track handles ←/→ (one card), Home and End.
- **Buttons and ARIA:** prev/next buttons carry `aria-controls` and are disabled at the ends. The highlights row also has 40px dot buttons (`aria-current`). Each wrapper has `role="region"` with `aria-roledescription="carousel"`, and each card is a "slide" labelled "n of N". Links and buttons inside cards are never turned into drags.

## In-page navigation (`lib/navigate.ts`)
- **Interception:** every same-page `#anchor` click goes through `goTo(id)`: nav links, the Menu sheet (after it closes), the hero CTAs and in-copy links.
- **Target:** the section's flow top (the pin spacer's position when a ScrollTrigger pin has lifted it out of flow) minus the 56px nav.
- **Scroll:** one GSAP ScrollTo tween, which works on Chromium 79, with `--ease-slide`, lasting 0.45s plus distance/6000, capped at 1.2s.
- **After it lands:** a correction against the live layout, `history.replaceState` for the hash, and focus on the section's h1/h2 (`tabindex=-1`, `preventScroll`).
- **Reduced motion:** instant.
- **Deep links:** they land once fonts load and the page settles, and are re-checked at 0.4s, 1.2s and 2.4s unless the visitor scrolls first.
- **Nav pill:** it holds on the destination for the whole jump rather than sweeping past other links.

## Closing and footer
- **Download:** the app icon, "Dashcast for Mac", one line, the primary CTA (the release .dmg, or GitHub as the fallback), Donate as the secondary button, then "macOS 15 or later · Apple silicon · v0.0.1".
- **Footer:** OpenHue/NotchTune pattern on the same photo behind a hairline. One row: icon, wordmark and tagline on the left; GitHub · Donate · David Lam on the right. Beneath it, one legal line.

## Layout
- **Breakpoints (TDS):**
  - phone: below 600
  - tablet portrait: 600–899
  - tablet landscape: 900–1199
  - desktop: 1200–1799
  - large: 1800 and up
- **Gutter:**
  - 32px at 1200 and up
  - 20px from 600 to 1199
  - 16px below 600
- **Content width:** max 1200px.
- **Section padding:** 104px desktop, 80px tablet, 64px phone. That's Tesla's specs table value.
- **Full-bleed sections:** `100vh` with a `100svh` override and a 600px minimum. The title block starts 96px from the top (80 on tablets, 72 on phones); the hero adds the 56px nav on top of that.
- **Chromium 79 floor:** people may open the site in the car, where the MCU2 browser is Chromium 79.
  - Use grid `gap` for gapped layouts, never flex `gap`.
  - Don't use `inset`, `:is()` or `aspect-ratio`.
  - The JS build targets chrome79.

## Motion
| Curve | Value | Used for |
|---|---|---|
| `--ease` / `ease.tds` | cubic-bezier(.5,0,0,.75) | nav hide, menu, panels |
| `--ease-mktg` / `ease.mktg` | cubic-bezier(.165,.84,.44,1) | every reveal |
| `--ease-slide` / `ease.slide` | cubic-bezier(.75,0,0,1) | the sliding pills, diagram nodes |

- **Small reveal:** 30px rise with an opacity fade, 0.5s. Opt in with `data-reveal="small"` and use `revealWithin(root)`.
- **Large reveal:** 100px rise, 1.5s. Used for section titles.
- **Photos:** a scroll-scrubbed zoom from 1.14 to 1 while the section enters, then a 6% drift while it leaves.
- **Hero load:** the cabin eases from 1.08 to 1 over 2.2s. The title, subtitle, CTAs and stats rise in a stagger.
- **Reduced motion:** every GSAP effect is skipped, the CSS durations collapse to 0.01s, and the diagram shows static dots.

## Reserved global class names (site lead)
The site's CSS is global. The other agents should prefix their classes; the demo agent's `.seg` already collided once.

`.nav*`, `.menu*`, `.wordmark*`, `.mark`, `.hero*`, `.split*`, `.srow*`, `.snap-track`, `.cards*`, `.card*`, `.g`, `.g-*`, `.o-*`, `.office*`, `.band*`, `.closing*`, `.foot*`, `.cmp*`, `.compare*`, `.faq*`, `.btn*`, `.btn-row`, `.stats`, `.stat*`, `.photo`, `.feature*`, `.highlights`, `.section`, `.section-head`, `.wrap`, `.connect*`, `.tabs*`, `.topo*`, `.kicker*`, `.steps*`, `.incar*`, `.tech*`, `.spec*`, `.mode*`, `.tiers*`, `.download*`, `.footer*`, `.t-*`, `.on-dark`, `.sr-only`
