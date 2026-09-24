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
- **Nav** (`sections/Nav`):
  - Layout:
    - fixed, 56px tall
    - three columns: wordmark / centred anchor links / GitHub icon
    - items are 32px tall, 16px padding, 4px radius, 14/500
  - Hover:
    - one **backdrop pill** slides between items: `transform` and `width` over .5s `--ease-slide`, with a separate .5s opacity fade
    - when you aren't hovering, the pill rests on the active section's link
  - Colour:
    - transparent with white text over the hero
    - past the hero, solid white with ink text (Tesla's `--stuck` state)
  - Scrolling:
    - scrolling down past the hero hides it (`translateY(-100%)`, .5s `--ease`)
    - scrolling up brings it back
  - Below 900px, the links collapse into a "Menu" pill. It opens a full-height white sheet with 56px rows, fading in over .5s `--ease`, and the rows follow with a 24px rise.
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

`.nav*`, `.menu*`, `.wordmark*`, `.mark`, `.hero*`, `.btn*`, `.btn-row`, `.stats`, `.stat*`, `.photo`, `.feature*`, `.highlights`, `.section`, `.section-head`, `.wrap`, `.connect*`, `.tabs*`, `.topo*`, `.kicker*`, `.steps*`, `.incar*`, `.tech*`, `.spec*`, `.mode*`, `.tiers*`, `.download*`, `.footer*`, `.t-*`, `.on-dark`, `.sr-only`
