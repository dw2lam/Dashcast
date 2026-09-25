# tesla.com: raw research notes (2026-09-24)

These notes were measured on `/`, `/model3`, `/modely` and `/models` at a 1600×879 viewport (DPR 2). Headless Chrome gets Akamai's "Access Denied" (403) even with UA, client hints and `navigator.webdriver` spoofed, so the measurements come from the Claude-in-Chrome MCP. I used JS in the page only: no `computer` screenshots, and my own tab, which I closed afterwards.

Scraped values are listed as-is. `DESIGN.md` has the distilled system.

## :root custom properties (TDS = Tesla Design System, TCL = Tesla component library)
682 custom properties resolve on `:root`. The ones that matter:

### Type
- **Families:**
  - `--tds-font-family-latin-display`: "Universal Sans Display", -apple-system, Arial, sans-serif
  - `--tds-font-family-latin-text`: "Universal Sans Text", -apple-system, Arial, sans-serif
  - Also present: "Blender TSL" (Cybertruck pages only), "CT Speed", and "Fira Code" (monospace).
  - `document.fonts` also lists "Super Sans VF" and "Inter", both unloaded on these pages.
- **Weights:** thin 100, light 300, regular 400, **medium 500**, bold 700. Pages only use 400 and 500.
- **Sizes and line-heights (px):**

  | token | font-size | line-height |
  |---|---|---|
  | 10 | 10 | 18 |
  | 20 | 12 | 20 |
  | 30 | 14 | 20 |
  | 40 | 17 | 24 |
  | 50 | 20 | 28 |
  | 55 | 23 | — |
  | 60 | 24 | 28 |
  | 70 | 28 | 36 |
  | 75 | 34 | 44 |
  | 80 | 40 | 48 |
  | 90 | 48 | 56 |
  | 100 | 56 | 64 |
  | 110 | 64 | 64 |
  | 120 | 72 | 72 |
  | 130 | 80 | 96 |

- `--tds-line-height-unitless`: 1.414
- Letter-spacing is `normal` everywhere I measured.
- **Body:** Universal Sans Text 14px/20px, `#393c41`, `-webkit-font-smoothing: antialiased`.

### Colour
- **Primary blue:**
  - `--tds-theme-primary` / `--tds-color-blue-30`: **#3e6ae1**
  - hover `--tds-theme-primary-highlight` / blue-20: **#3457b1**
  - others: blue-10 #2e4994, blue-40 #3368ff
- **Foreground:**
  - high-contrast #171a20 (headings, nav)
  - foreground #393c41 (body)
  - low-contrast #5c5e62 (labels, footer)
- **Greys:**
  - 10 #171a20, 15 #222, 20 #393c41, 25 #444, 30 #5c5e62, 33 #707070, 35 #8e8e8e
  - 40 #a2a3a5, 45 #bbb, 50 #d0d1d2, 60 #e2e3e3, 65 #eee, 70 #f4f4f4
- **Theme surfaces:**
  - background #fff
  - container #f4f4f4
  - container-highlight #eee
  - border #d0d1d2
  - border-low-contrast #e2e3e3
  - container-alt `#0000000d` (5% black; the nav hover pill)
  - container-alt-highlight 7.5% black
- **Status:**
  - positive #12bb00
  - warning #fbb01b
  - negative #b74134
  - red #ed4e3b
- **Gradients:**
  - `--tcl-gradient-blue-center`: `linear-gradient(90deg, #171a20, #3e6ae1, #171a20)`
- **Section scrims:**
  - `--tcl-section-start-gradient` / `--tcl-section-end-gradient`: #000 → #0000 over 20% of the block, at 0.5 opacity. These sit over photos so the type stays legible.

### Space, shape and effects
- `--tds-size--Nx` = N × 8px, half = 4px, up to 13x = 104px.
- **Radii:**
  - `--tds-border-radius`, `--pill` and `--card`: all **4px**
  - `--tcl-border-radius`: 8px
  - circle: 100%
- **Borders:** hairline 0.5px, small 1px, medium 2px, large 3px.
- **Shadows:**
  - small `0 4px 8px #00000014`
  - medium `0 8px 16px #0000001f`
  - large `0 8px 16px #00000029`
- **Blur:**
  - `--tds-blur--button`: 16px (nav pill, buttons)
  - large 8px, small 4px
- **Opacity steps:** 0 / .3 / .5 / .7 / 1

### Motion
- `--tds-bezier` / `--tds-animation-bezier-base`: **cubic-bezier(0.5, 0, 0, 0.75)**. Panels and modals use it at .5s.
- `--tds-animate-transition-function--mktg`: **cubic-bezier(0.165, 0.84, 0.44, 1)**, which is easeOutQuart (GSAP `power3.out`).
- **Durations:** short 500ms, medium 600ms, long 1500ms.
- **Base function:** linear, property opacity.
- **Reveals:**
  - `.tds-animate_small--to_reveal`: opacity 0 plus `translate3d(0,30px,0)`, animated back over 500ms with the mktg ease.
  - `.tds-animate_large--to_reveal`: `translate3d(0,100px,0)` over 1500ms, mktg ease.
- **Animated backdrop:** carousel dots and tab lists use `--tds-animate-backdrop-transition: .5s cubic-bezier(.75,0,0,1)`. Left, top, width and height move through CSS variables, and a separate `opacity .5s ease` fades it.
- **UI colour transitions:**
  - buttons: `border-color .33s, background-color .33s, color .33s, box-shadow .25s`
  - nav items: `color .33s, background-color .33s`
  - header: `background-color .33s, box-shadow .33s`
- **Modals:**
  - closed: `opacity 0; translateY(50%)` (phone) or `translateY(100%)` (≥600)
  - open: transition `opacity .5s var(--tds-bezier), transform .5s var(--tds-bezier)`
  - backdrop: 0.3 black plus `blur(4px)`

## Header / nav (.tds-site-header)
- **Height:** 56px (`--tds-site-header--height`). It is `position: relative` on marketing pages, so it scrolls away. A `--sticky` variant exists, and in its `--stuck` state it gets `background-color: var(--tds-theme-background)`.
- **Layout:** three flex columns (logo, centre items, end icons).
- **Inline padding:** 8px below 600, 20px at 600 and up, 32px at 1200 and up.
- **Nav item (.tds-site-nav-item):**
  - inline-flex, 32px tall, padding 4px 16px, radius 4px
  - 14px/20px, weight 500
  - colour #171a20 on light heroes and white on dark ones
  - transition `color .33s, background-color .33s`
- **Hover:**
  - `.tds--hovered` (set by JS) or `:hover`
  - gets `backdrop-filter: blur(16px); background-color: var(--tds-theme-background-container-alt)`, which is 5% black
  - `.tds-animate--backdrop` items instead share one absolutely positioned `.tds-animate--backdrop-backdrop` pill. It is moved with CSS variables and uses the .5s cubic-bezier(.75,0,0,1) transition above.
- **Centre items:** Vehicles · Energy · Charging · Discover · Shop.
- **End:** three icon-only 32×32 items (support, region, account).
- **Phone/tablet (below 1200):** the centre items collapse. A panel opens full-height on phones (`min-block-size: 100dvh`). At 1200 and up it drops from the top instead: `translateY(-96px)` to 0 over .5s `--tds-bezier`, with its content following from `translateY(72px)`.

## Home hero (/)
- **Stacked carousel:** each slide is a full-bleed photo or video. The height is the viewport minus banners (`.tcl-dynamic-section--block-size--viewport`).
- **Heading container:** padding `48px 32px 32px`. The title sits 48px below the header.
- **Title:**
  - Universal Sans Display, 48px/56px, weight 500
  - white on dark media, centred
  - top at y = 104 (header 56 + 48)
- **Subtitle:** Display 20px/28px weight 400, 4px below the title.
- **CTAs:**
  - start 24px below the subtitle
  - two buttons, 200×40 each, 8px apart
  - primary `#3e6ae1`
  - secondary is "tcl-btn--high-contrast": white fill with #393c41 text on dark media

## Model pages (/model3, /modely, /models)
- **Hero title:** 56px/64px (Model 3/Y) or 64px/64px (Model S), weight 500, white, centred.
- **Hero subtitle:** 20px/28px, weight 500 or 400.
- **CTAs:** "Order Now" (primary) plus "Compare Models" or "Browse Inventory".
- **Section titles:** "Meet Model 3" is 48px/56px weight 500 #171a20, centred. The subhead is 28px/36px, and a 20px/28px low-contrast line follows.
- **Badge rows** (`.tcl-badge-group`):
  - flex, centred, 1px separators coloured `--tds-theme-border`
  - Model Y (inline in a section):
    - gap 32px
    - value 34px/44px Display 500 #171a20
    - unit 20px/28px Display 500, 4px after, bottom-aligned
    - label 14px/20px Text 400 #5c5e62
  - Model S (its own white section right after the hero):
    - gap 80px
    - value **64px/64px**, unit **28px/36px**
    - label **20px/28px** Display 500 #5c5e62
    - the three stats are "410 mi / Range (EPA est.)", "1.99 s / 0-60 mph" and "1,020 hp / Peak Power"
- **Specs table** (`.tcl-specs-table-v2 .tds-scrim--black`):
  - black background, padding 104px 0
  - "Model 3 Specs" title 28px/36px
  - group heads 20px/28px #eee
  - labels 14px/20px #8e8e8e
  - values 14px/20px #fff with 14px bottom padding
  - four columns, each 198px wide
- **Buttons** (`.tds-btn`):
  - height `--tds-height--pill` 40px
  - border 3px transparent
  - radius 4px
  - padding 4px 24px
  - Universal Sans Text 14px weight 500, line-height 1.2
  - primary `#3e6ae1`, hover `#3457b1`
  - secondary is transparent with a 3px border in the high-contrast colour, and inverts on hover
  - tertiary `#f4f4f4`
  - `tcl-button-group .tds-btn` inline size 252px, but the hero CTAs measured 200px
  - below 600px buttons fill the available width (`-webkit-fill-available`); button groups become horizontal at 600 and up
- **Footer** (`.tds-site-footer`):
  - centred row of `li.tds-footer-item` links
  - Text 12px/20px, weight 500, #5c5e62
  - padding `0 24px 60px`
  - items: "Tesla © 2026 · Privacy & Legal · Vehicle Recalls · Contact …"

## Breakpoints seen in the CSS
- **TDS tiers:** 600, 900, 1200 and 1800. The tiers are phone-only below 600, tablet-portrait 600–899, tablet-landscape 900–1199, desktop 1200–1799, and large desktop 1800 and up. The utility classes are `.tds--hideon-phone-only`, `-tablet-portrait-only`, `-tablet-landscape-only`, `-desktop-only` and `-desktop-large-up`.
- **Other queries seen:** 450, 640, 840, 975, 1240, 1440, 1600, 2040 and 2559, plus `(max-height: 600px) and (orientation: landscape)`.

## Type specimen
- `refs/tesla-type.png` is git-ignored and is a reference only.
- I rendered it with the page's own loaded Universal Sans onto a canvas and exported the pixels. It shows "Dashcast Rag 60" at 56px Display 500, the subtitle at 20px Display 400 and "Download for Mac" at 14px Text 500.
- **Glyph metrics at 100px, via canvas `measureText`:**

  | face | x-height | cap height | descender | x-height / cap |
  |---|---|---|---|---|
  | Display 500 | 49.8 | 70.4 | 19.0 | 0.707 |
  | Text 500 | 49.8 | 70.4 | 19.0 | — |

  Text 500 runs about 7% wider per glyph than Display 500.

## Round 3: tesla.com today (re-measured 2026-09-24, 1600×879, Claude-in-Chrome, JS only)

### Nav (home page)
- `header.tds-site-header` sits inside `.tds-site-header-wrapper`, which has **`background: #fff`**. That wrapper sits inside a **`section` with `position: sticky; top: 0`**.
- The result: a solid white 56px bar that is **always visible**. It doesn't hide on scroll and has no shadow. At scrollY 1500 the header is still at top 0.
- The hero starts **below** it (y = 56).
- **Links:** Vehicles · Energy · Charging · Semi · Discover · Shop, in #171a20 at 14px/500. Three icon buttons on the right; the wordmark is 152×24 in #171a20.
- **Model pages differ:** on /modely the header is transparent over the hero and not sticky. David asked for the home-page behaviour.

### Home-page rhythm
White page, 48px side margins everywhere below the hero.
1. **Hero carousel:** full-bleed, 1600×643 (viewport minus header and banners). White 48/56 title, 20/28 subtitle, blue + white 160–200×40 CTAs.
2. **Split card** (FSD):
   - #f4f4f4, **8px radius**, 1504×508.
   - Text panel on the left, padding 48: 40/48 title, 34/44 stats with labels, then dark `#171a20` and white buttons.
   - Video on the right, 902×508, radius `0 8 8 0`.
3. **Card carousel** (vehicles):
   - 48px top padding; cards 1024×580, 8px radius, 24px gap; the next card peeks in.
   - Overlay 40px from the bottom-left: 48/56 white title, 20/28 subtitle, two 160×40 buttons (blue, white).
   - Controls: a 40×40 arrow at 75% white, 4px radius, 48px from the edge; 12px dots with 8px gaps, 24px below.
4. **Two tall cards** (Offers and Inventory): each 740×800, #f4f4f4, 8px radius, 24px gap. Copy at the top-left with padding 32/24/32/48: 34/44 title, 20/28 grey subtitle, a white tertiary button. Image below.
5. **Charging map:** 48/56 title, 20/28 subtitle, dark primary and #f4f4f4 tertiary buttons.
6. Another card carousel (Solar).

### Model Y page rhythm
- Full-bleed hero, then mostly **white** sections, one more full-bleed band ("Explore Model Y" with badges), then the black specs and "Design Yours".
- **"Meet Model Y":**
  - centred 48/56 title, 28/36 subtitle, 20/28 grey line
  - **feature-card carousel** of 430×500 cards (`tds-card-root`, 8px radius, overflow hidden) on a native horizontally scrolling track (`tds-carousel-items`, `overflow: auto`)
  - 34px white card titles 24px in from the bottom-left, and a round white "+" on each card
  - 40×40 prev/next controls on #f0f0f0, 4px radius, at the section edges
- **"Everything You Want":** a left-aligned 48/56 heading with a 20/28 grey paragraph, then a text-only **three-column grid** of 34/44 titles over 20/28 grey copy.

### Support FAQ (en_my/support/faq)
- **Structure:** `ul.tcl-accordion__controls` (padding 8 24 32) → `li.tcl-accordion__item` (flex column, **24px bottom padding, no dividers**) → `button.tcl-accordion__control`.
- **ARIA:** `aria-expanded` plus `aria-controls` pointing at `div.tcl-accordion__panel` (with `aria-hidden`).
- **Question row:**
  - a **30×30 right-pointing chevron to the left** of a 14/20 question in #393c41
  - when open, the chevron turns `rotate(90deg)` (transform 0.5s) with stroke-width 2, and the question turns #171a20
- **Panel:**
  - closed: `max-height: 0; overflow: hidden; transition: margin .5s, max-block-size .5s`
  - open: 8px top margin and `max-height: none`, so the height itself snaps
  - answer text 14/20 #393c41
- **Behaviour:** several items can be open at once.
- **Headings and width:** section heading 28/36 medium (page titles 34/44 or 40/48); content column 774px.

### Compare (/compare)
- 40/48 title "Compare Models", a sticky left rail of 14/20 medium grey category links (220px), and model columns 400px wide with 24px gaps.
- Column header: 28/36 model name, 17/28 grey trim name, 40px CTA.
- Each property is a block: a 20/28 medium heading spanning the row, then values per column at 24/28 medium ink with a 14/20 grey note. "-" marks "not applicable".
- 104px between blocks and no hairlines.

## Round 7: spacing audit (re-measured 2026-09-24/25, Claude-in-Chrome, JS only)
Measured at 1600×879 on /, /modely and /model3. For 1024, 820 and 390 I loaded the same-origin pages in iframes of that width inside the tab and read their layout, so no window resize and no screenshots.

### Section padding
Model pages set it per section with CSS variables on `.tcl-section-padding`:
`--tcl-section-padding-{desktop|tablet|mobile}-block-{start|end}`.
- **Desktop (≥900):** 152px top and bottom on story sections ("Always Connected", "Engineered for Your Safety"…).
- **Tablet and mobile (<900):** 72px.
- **"Meet Model Y" (first after the hero):** 72/160 on desktop, 72/104 on tablet, 80/104 on mobile.
- **Specs:** 104px.
- **Home page:** a stack of modules 48px apart on desktop (split card, card rows), 24–40px on tablet, 24px on phone.

### Heading block
- **"Meet Model Y":**
  - ≥1200: title 48/56 500, then a 28/36 subhead flush below it, then a 20/28 #5c5e62 line 4px lower; the card row starts **48px** under that.
  - 1024 and 820: title 40/48 with content 48px below.
  - 390: title 40/48 with content 48px below.
- **"Everything You Want":** left-aligned 48/56 title with a 20/28 grey paragraph 4px under it; the info-card grid starts 64px lower (40px on a phone).
  - Cards are 400 wide, with padding 32 top and 48 bottom, a 24px column gap and a 12px row gap.
- **Phones keep 40/48 section titles and 20/28 subtitles.** Model heroes are 48/56 on phones (56/64 on desktop).

### Gutters and width
- **`--tds-content_container--gutter`:** 24px below 600, 36px from 600, 48px from 1200.
- **Text column at 1600:** x=175, width 1249. That's a 12-column grid on the 1504px row, inset one column.
- **Home cards on a phone:** 12px from the edge, with copy 24px inside the card.

### Photo sections
- **"Explore Model Y":** a centred title 64px below the photo's top edge (48 at 390).
- **Home hero:** title 48px under the 56px header.
- **Home photo cards:** copy sits bottom-left, 40px in.

### Controls
- **Carousel dots:** 12px; 4px apart on /modely, 8px on the home page; 24px under the cards.
- **Arrows:** 40×40, radius 4.
- **Home buttons at 1024:** 164×40 with an 8px gap.
- **Header:** always 56px.

### What we took
- `--section-pad` 104 (≥900) / 72 (<900). We use the specs value, not the 152 story padding: 11 sections at 304px of air each would read as empty, and David has asked for tighter.
- `--head-gap` 48 everywhere.
- Gutters 48/36/24.
- Phone titles 40/48 with 20/28 subtitles; phone hero 48/56.
- Photo titles 64/48.
- Dots 12px.
