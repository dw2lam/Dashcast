# Dashcast site: design system

The site copies **tesla.com's** own design system (TDS). The values were measured live on 2026-09-24; the raw data is in `research/tesla-web/NOTES.md`. All tokens live in `src/styles/tokens.css`. Use the variables and never hard-code these values.

## Principles (Tesla's, applied)
1. **One idea per full-viewport section.** Use a real photo, full bleed. The title is centred at the top, the stats run along the bottom, and nothing else goes on the photo.
2. **Few words.**
   - A title (2–5 words), one subtitle line, and at most two CTAs.
   - Detail goes in label/value stats, never in paragraphs.
3. **One accent.**
   - Tesla blue `#3e6ae1` is only for the primary CTA.
   - The Dashcast gradient (`#0872fe → #15abfe → #18d3fd`) only appears on the mark, the diagram signals and the one IP address; a section gets at most one brand accent.
4. **Flat and quiet.**
   - All radii are 4px.
   - Lines are 1px hairlines.
   - There's no glass shine. The only blur is the 16px behind nav pills.
5. **Motion lives in the media (round 8).**
   - tesla.com today has no scroll reveals, no parallax and nothing scrubbed. The header fades in on load; after that, only media move: autoplaying loops, carousels, a crossfading vertical carousel.
   - Content is simply there. Everything turns off under `prefers-reduced-motion`.

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
| Hero title | 64/64 | 56/64 | 48/56 | `.t-hero` |
| Section title | 48/56 | 40/48 | 40/48 (tesla.com keeps 40/48 at 390px) | `.t-section` |
| Block title | 28/36 | 28/36 | 28/36 | `.t-title` |
| Subtitle | 20/28 regular | 20/28 regular | 20/28 regular | `.t-sub` |
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
| Dark section | #000 bg, #fff values, #8e8e8e labels, 14% white hairlines | every dark section: Office, Tech, the Band's backdrop |
| `--grad-brand` | #0872fe → #15abfe → #18d3fd | the Dashcast mark, diagram signals, the IP |
| `--c-brand-2` | #15abfe | the one accent inside a section's media (the gesture tiles' caret, hold ring and key taps) |
| Wallpaper | #011138 → #0a3f93 → #0b52e0 | any drawn Mac screen (gesture tiles, the office drawing), taken from `public/shots/wallpaper.jpg` |

**One palette (round 8).** Removed: the office graphite `#111317` and its fills `#0b0c0f #23262d #2d3139 #1c1f25`; the dark tile gradient `#2b3240 → #1b1e25 → #15171c` (Touch and the old split panels); the purple screen gradient `#1d3b7a → #35307a → #5b2a7a`; the brand gradient as a screen fill in the office drawing; the brand-blue step numbers; the closing's `#08090b` night backdrop and its scrims; the Band's `#1a1c20`; the macOS traffic-light red/yellow/green in the gesture art (now #c9ccd3); Tesla blue as the gesture caret (now the one brand accent). The native Mac captures keep their real colours.

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
- **Segmented** (`ui/Segmented`, `.ui-seg*`; shared with the demo):
  - a 40px track (4px inset, 4px radius), 32px segments at 14/500, one pill sliding to the active one (.5s `--ease-slide`)
  - light: #f4f4f4 track, white pill, grey → ink text; dark: 10% white track, 20% white pill, 64% → 100% white text
  - `semantics="radiogroup"` (a setting) or `"tablist"` (switches a panel: pass `controls` and `idPrefix`); roving tabindex, arrows, Home, End; 44px hit areas on touch
- **Media row** (`sections/MediaRow`, `.mrow*`): the "media + content row" template, below.
- **Tabs** (`.tabs` in Connect, kept as David likes it):
  - #f4f4f4 track with 4px padding
  - a white pill with a soft shadow slides under the active tab (.5s `--ease-slide`)
  - arrow keys move between tabs
- **Scrims:** Tesla's section start/end gradients, black to transparent from the top and the bottom, so white type stays legible on any photo.

## Template catalogue (round 8, measured 2026-09-25 on /, /modely, /model3 and /powerwall at 1600–1800px)
Every section is one of these. Numbers are Tesla's at 1800px unless noted; the raw notes are in `research/tesla-web/NOTES.md`.
- **Hero** (home): full-bleed media under the 56px header; centred 48/56 title 48px below it, 20/28 subtitle, a blue + white 160–200×40 pair.
- **Card carousel** (home, "Solar Panels · Powerwall · Megapack"; `tcl-freeflow-carousel`):
  - 1024×580 image cards, 8px radius, 24px apart, the row starting at the page margin, the next card peeking.
  - Copy 40px in from the bottom-left of the image: 48/56 white title, 20/28 white subtitle, a 160×40 blue `#3e6ae1` + white (`#393c41` text) pair 24px below, 8px apart.
  - One 40×40 arrow, white at 75%, 4px radius, vertically centred, 48px from the viewport edge, over the peeking card's image (the previous one appears once you've moved).
  - Dots: 12px, 8px apart, 24px under the cards; every dot `#171a20`, inactive ones at 50% (reads as ≈#8b8d90); the state switches instantly (Tesla transitions colour, not opacity). Native scrolling.
- **Split card** (home, FSD): a #f4f4f4 card, copy column (padding 32/48/16: 40/48 title, 17/24 grey subtitle, a row of 34/44 stats with 17/24 labels, 40px apart) beside a video flush right.
- **Grey tile pair** (home, "Current Offers | Inventory"): two #f4f4f4 tiles, 8px radius, 24px apart; copy padded 32/24/32/48 (34/44 ink title, 20/28 #5c5e62 subtitle, white 180×40 buttons 16px lower); the image in the tile's right third, full height, or bleeding off its edges.
- **Media + content row** (home, "Find Your Charge", from David's screenshot; the module is a lazy React bundle): a rounded media block across the content width, then a row: left-aligned 48/56 title, one subtitle line and a dark + light grey button pair on the left; big stats with small round icons on the right.
- **Info-card grid** (/modely, "Everything You Want"): a left-aligned 48/56 title with a 20/28 grey paragraph 4px under it; cards 64px lower (400 wide, 24px column gap) with 34/44 titles and 20/28 grey text.
- **Feature-card carousel** (/modely, "Meet Model Y"): centred 48/56 title, 430×500 cards 16px apart, 12px dots 4px apart.
- **Photo section** (/modely, "Explore Model Y"; /powerwall "text on media"): full-bleed 16:10 photo, the title 64px under its top edge (centred), or a 28/36 heading and 14/20 text over its bottom in the 12-column main column.
- **Vertical carousel** (/powerwall): a 432px list of 24/28 titles (inactive #d0d1d2, active white, the active one opening its 14/20 text) beside 620×465 media with an 8px radius; the media crossfade over .8s ease-in-out and the list advances by itself.
- **Specs table** (/model3, /powerwall): black, a 28/36 title, groups of 14/20 grey labels over white values.
- **Support accordion** (/support/faq) and **/compare**: see FAQ and Compare below.
- **Motion on all four pages:** `body.animate-onscroll` with no `tds-animate_*` element anywhere, `tcl-parallax-effect--off`, the header's 1s fade-in on load, muted looping autoplay video, native carousels, the Powerwall carousel's crossfade. No reveals, no parallax, nothing scrubbed.

## Section map (round 8)
| # | Section | Template | Surface | Notes |
|---|---|---|---|---|
| 1 | Hero | Hero | full-bleed | **kept** (David likes it); its load stagger and scroll-out fade stay as they were |
| 2 | Highlights `#features` | Card carousel | white | Extend (photo) · Sound (`SoundVisual`) · MCU (`McuVisual`); blue "Try the demo" + white "Learn more"; arrows over media, Tesla dots |
| 3 | Demo `#demo` | Media + content row | white | `DemoStage` in the #f4f4f4 block; Display and Car computer as Segmented; 60 fps · 48 kHz stats |
| 4 | The Mac app `#app` | Media + content row | white | the pair's second half: same block, same 16:10 stage; chapter tabs + Light/Dark; chapters advance every 7s until one is picked; 1 window · 3 steps |
| 5 | Touch is the mouse | Info-card grid | white | left heading; five #f4f4f4 tiles with the wallpaper-blue screens |
| 6 | Your office, anywhere | Vertical carousel | black | steps on the left, our drawing on the right showing the active step; advances every 4.8s until one is picked |
| 7 | "Nothing to install in the car." | Photo section | full-bleed | static (no zoom) |
| 8 | Connect | (its own tabs + diagram) | white | **kept**; only the Phone Hotspot copy changed |
| 9 | Under the hood | Specs table | black | **kept** |
| 10 | Compare | /compare | white | kept: it already follows /compare |
| 11 | FAQ | Support accordion | white | kept (coordinator's spec) |
| 12 | Download `#download` | Grey tile pair | white | "Dashcast for Mac" (Download / GitHub, the app icon) · "Support Dashcast" (Donate, the Supercharger photo bleeding off the bottom), then the footer on white |

The demo and the Mac app are a matched pair: back to back, the same #f4f4f4 block (`--mrow-h`: the 16:10 stage plus padding, capped at 600px), the same row under it; the second one drops its top padding so the two read as one set.

## Compare and FAQ
- **Compare** (`sections/Compare`, `.cmp*`): Tesla's /compare pattern: a label column plus "Dashcast" and "Others"; 20/28 values with 14/20 notes; a blue check or grey dash; hairline rows. Below 600px the label sits above both values.
- **FAQ** (`sections/Faq`, `.faq*`): Tesla's support accordion; a 30px chevron left of each 14/20 question, no dividers, several open at once, `aria-expanded` → `role="region"` panels.

## Carousel input (`hooks/useCarousel.ts`, the card carousel)
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
- **Buttons and ARIA:** 40×40 arrows (`.fcards__arrow`, white at 75%) carry `aria-controls`, sit over media only and hide at the ends; hover screens of 900px and up. The dots (`.fcards__dot`) are Tesla's 12px, 8px apart, with a 24×40 tap area from `::after` (neighbouring areas overlap by 4px). Each wrapper has `role="region"` with `aria-roledescription="carousel"`, and each card is a "slide" labelled "n of N". Links and buttons inside cards are never turned into drags.

## In-page navigation (`lib/navigate.ts`)
- **Interception:** every same-page `#anchor` click goes through `goTo(id)`: nav links, the Menu sheet (after it closes), the hero CTAs and in-copy links.
- **Target:** the section's flow top (the pin spacer's position when a ScrollTrigger pin has lifted it out of flow) minus the 56px nav.
- **Scroll:** one GSAP ScrollTo tween, which works on Chromium 79, with `--ease-slide`, lasting 0.45s plus distance/6000, capped at 1.2s.
- **After it lands:** a correction against the live layout, `history.replaceState` for the hash, and focus on the section's h1/h2 (`tabindex=-1`, `preventScroll`).
- **Reduced motion:** instant.
- **Deep links:** they land once fonts load and the page settles, and are re-checked at 0.4s, 1.2s and 2.4s unless the visitor scrolls first.
- **Nav pill:** it holds on the destination for the whole jump rather than sweeping past other links.

## Closing and footer
- **Download** (the grey tile pair): "Dashcast for Mac" with the release .dmg (or GitHub as the fallback) and GitHub as white buttons, the version and size, and the app icon at the tile's bottom right; "Support Dashcast" with Donate and the Supercharger photo bleeding off the bottom.
- **Footer:** OpenHue/NotchTune pattern on white behind a hairline. One row: icon, wordmark and tagline on the left; GitHub · Donate · David Lam on the right. Beneath it, one legal line.

## Layout
- **Breakpoints (TDS):**
  - phone: below 600
  - tablet portrait: 600–899
  - tablet landscape: 900–1199
  - desktop: 1200–1799
  - large: 1800 and up
- **Gutter (`--gutter`, round 7):** Tesla's `--tds-content_container--gutter`.
  - 48px at 1200 and up
  - 36px from 600 to 1199
  - 24px below 600
- **Content width:** max 1200px. Tesla's text column at 1600 is 1250, one grid column in from its 48px gutters.
- **Section rhythm (round 7, one rule for every white or dark section):**
  - `--section-pad` is 104px at 900 and up and 72px below. That's Tesla's specs section on desktop and its model-page sections under 900. Adjacent sections get 208px or 144px of air.
  - Title → subtitle is 4px (`.section-head .t-sub`).
  - `--head-gap`, the space from the heading block to the content, is 48px at every width. That's "Meet Model Y" at 1600, 820 and 390.
- **Exceptions, on purpose:**
  - The card carousel keeps Tesla's home-page module rhythm: 48px (24 on phones), with no visible heading.
  - The demo and the Mac app use the media + content row: media first, the row 40px under it (32 on phones), stats on the right; `#app` has no top padding so the pair reads as one set.
  - The download tiles end 48px above the footer.
- **Photo sections:** the title sits `--photo-title-top` below the photo's top edge: 64px, or 48 on phones ("Explore Model Y"). The hero's content starts 48px under the header.
- **Chromium 79 floor:** people may open the site in the car, where the MCU2 browser is Chromium 79.
  - Use grid `gap` for gapped layouts, never flex `gap`.
  - Don't use `inset`, `:is()` or `aspect-ratio`.
  - The JS build targets chrome79.

## Motion (round 8: Tesla's, measured)
| Curve | Value | Used for |
|---|---|---|
| `--ease` / `ease.tds` | cubic-bezier(.5,0,0,.75) | menu, panels, the office screen swivel |
| `--ease-mktg` / `ease.mktg` | cubic-bezier(.165,.84,.44,1) | windows settling in the Mac app, the office board and MacBook |
| `--ease-slide` / `ease.slide` | cubic-bezier(.75,0,0,1) | sliding pills (nav, Segmented, tabs), carousel glides, diagram nodes |

- **No scroll reveals, no parallax, nothing scrubbed.** `revealWithin` is a no-op kept for old callers; `data-reveal` attributes are gone from the site lead's sections.
- **Load:** the header fades in over 1s (Tesla's `tds--fade-in`). The hero keeps its own load stagger and scroll-out fade (kept section).
- **Media only:** the demo loop, `SoundVisual`/`McuVisual`, the gesture tiles (only while on screen), the Mac app's chapters (7s each, windows glide .9s with Tesla's curves, captures crossfade), the office steps (4.8s each; each step animates only what it adds). Anything that advances by itself stops as soon as someone picks a tab or step, and only runs while its section is on screen.
- **Carousels:** native scroll; arrows and dots glide with `--ease-mktg`; the dot state switches instantly, like Tesla's.
- **Reduced motion:** no loops or autoplay, instant state changes, CSS durations collapse to 0.01s, the header doesn't fade.

## Reserved global class names (site lead)
The site's CSS is global. The other agents should prefix their classes; the demo agent's `.seg` already collided once.

`.nav*`, `.menu*`, `.wordmark*`, `.mark`, `.hero*`, `.fcard*`, `.fcards*`, `.mrow*`, `.ui-seg*`, `.ctile*`, `.app-row*`, `.demo-row*`, `.sc*`, `.snap-track`, `.touch*`, `.tile*`, `.g`, `.g-*`, `.o-*`, `.office*`, `.band*`, `.closing*`, `.foot*`, `.cmp*`, `.compare*`, `.faq*`, `.btn*`, `.btn-row`, `.stats`, `.stat*`, `.photo`, `.feature*`, `.highlights`, `.section`, `.section-head`, `.wrap`, `.connect*`, `.tabs*`, `.topo*`, `.kicker*`, `.steps*`, `.incar*`, `.tech*`, `.spec*`, `.mode*`, `.tiers*`, `.download*`, `.footer*`, `.t-*`, `.on-dark`, `.sr-only`
