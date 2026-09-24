# The Tesla centre screen, measured (for the in-car demo)

Everything the demo draws comes from here. Pixel values are at the panel's native 1920×1200, and fractions are of the full screen. The references are in `refs/` (git-ignored, never shipped), and `refs/manifest.json` lists each file's source, state, software version and whether it is a native capture or a photo. The tools that produced the numbers are in `tools/`, and the headless checks are in `harness/`.

## Sources, most useful first

1. **Tesla Android docs** (tesdroid.com, "full screen mode"). Five native 1920×1200 captures (`screen-QtCar-2023-10-18-*`) from a Model 3 on 2023 software. They show:
   - the windowed browser (`01`–`03`)
   - the youtube.com/redirect Theater view, both just launched (`04`) and settled (`05`)
2. **tesla-qemu** (github.com/06066060606060/tesla-qemu, `docs/qtcar.jpg`). Tesla's own UI binary from MCU2 (Intel) firmware, running in an emulator. It gives the dark home screen, dock and status bar (`06`). The map and car assets are missing there.
3. **Not a Tesla App.** Native captures downscaled to 1200×750:
   - the 2024.32 windowed browser with the new toolbar (`07`)
   - 2024–2025 light home, app and controls screens (`11`, `12`, `25`)
   - dock and status-bar crops (`13`–`15`)
   - photos of 2026.26 on a Juniper (`16`, `17`)
4. **Owner's manuals** (tesla.com PDFs, 2026.26). Annotated touchscreen overviews for the Model 3 2024+ and 2017–23, which are the same as the Model Y 2020–24 (`08`, `09`).
5. **Photos and video frames:**
   - SideDisplay's hero photo: expanded browser, dark toolbar (`18`)
   - Theater band on a Highland and a Model Y (`19`–`22`); `20` is perspective-rectified
   - expanded browser, light theme (`23`)
6. **Dashcast itself:**
   - `Web/src/` (client markup and CSS)
   - `Sources/DashcastContracts/Contracts.swift` (tiers)
   - `Sources/DashcastServer/Session/TierSelector.swift` (encode size and virtual display size)
   - the real client against `Web/dev/mock-server.mjs` in headless Chrome, for the stats overlay values

Reddit returned 403 and was not used.

## Screens

| Model | Centre screen | Pixels / orientation | Computer |
|---|---|---|---|
| Model 3 2017–23 | 15" | 1920×1200, landscape | MCU2 (Intel Atom) until about Dec 2021, then MCU3 (AMD Ryzen) |
| Model 3 Highland 2024+ | 15.4" (+ 8" rear) | 1920×1200, landscape | MCU3 |
| Model Y 2020–24 / Juniper 2025+ | 15" / 15.4" (+ 8" rear on Juniper) | 1920×1200, landscape | MCU2 until about late 2021, then MCU3 |
| Model S/X 2012–20 | 17" | 1200×1920, **portrait** | MCU1 until about Apr 2018, then MCU2 |
| Model S/X 2021+ | 17" (+ 8" rear) | 2200×1300, landscape | MCU3 |
| Cybertruck | 18.5" (+ 9.4" rear) | 2560×1440 (sources disagree) | MCU3 |

**What looks different on MCU2 and MCU3** (NTA #2417):
- **Parked:** MCU2 keeps the split view, car on the left and map on the right. MCU3 on v12 shows a full-screen visualization.
- **Overlays:** MCU2 uses solid or semi-transparent overlays; MCU3 uses blur.
- **Features:** MCU2 has fewer games and no Steam.
- **Expand button:** the browser's expand button (2024.14) is on both.
- **Browser engine:** Chromium 148 arrived in 2026.26. Nothing says whether MCU2 got it too.

**The demo's honest MCU2 vs MCU3 differences** come from Dashcast's own tiers, not from the car UI:
- **MCU2:** H.264 Main at 30 fps, frame 1242×736.
- **MCU3:** HEVC at 60 fps, frame 1920×1138.
- In the demo, MCU2 is softer and moves at 30 fps.

## Browser viewport

- **Before 2026.26:** DPR 1.0.
- **2026.26 (Chromium 148):** DPR **1.53**, and `screen` = 1254/1255×784 CSS px. That is the whole panel. Source: the codriver.io developer on TMC, measured on a 2024 Model Y.
- **Windowed browser page area:** x 740–1920, y 179–1100 = 1180×921 px = **771×602 CSS**. Codriver independently reported 773×601.
- **Theater (youtube.com/redirect):**
  - a **60 px black band** at the top, and the page below it: 1920×1140 px = **1255×745 CSS**
  - native 2023 capture, and consistent with the 2025 photos
  - Android's own status bar starts at y 60, so the band pushes the page down rather than covering it
- **Verdict on the 1255×784 @1.53 probe:**
  - it is `screen.*`, the full panel, and the same size `Web/dev/cdp-probe.mjs` emulates
  - `innerHeight` in Theater should be about 745
  - confidence: medium; one log of `innerHeight` / `visualViewport.height` in the car would settle it
- **Consequences for the demo:**
  - Extend makes a 1255×745 pt virtual display (`TierSelector.displaySize`)
  - `encodeSize` gives 1242×736 for mcu2 and 1920×1138 for mcu3-hevc
- **Expanded mode** (the browser's own expand button): the toolbar stays, about 120 px, so the page is about 1255×706 CSS. Low confidence; it comes from photos only.

## Layout at 1920×1200

**Dock:**
- Size: y 1100–1200, i.e. 100 px or **8.33%** of the height. Background #000. Item centres at y 1149.
- Items, in order:

| Item | Centre x | Size / style |
|---|---|---|
| Car icon | 80 | 46×34, #999 |
| Driver temperature | 320 | thin, about 48 px, #b2b2b2; chevrons #454545 at 237 and 402 |
| Seat heater | 500 | "Auto" above it |
| App tiles | 660, 760, 860 … | 100 px pitch; 40×40 full-colour tiles, radius about 5; 44×44 from 2026.14 |
| "…" launcher | – | – |
| Volume | 1547 | #bfbfbf; chevrons at 1467 and 1632 |

- **Split climate:** the passenger temperature sits at about 1551 and the volume moves to 1816.
- **Open-app bar:** #7f7f7f, 60×4, at y ≈ 1195, under the open app.
- The cabin photo's own dock (2023–24 software, Model Y) has: car 71, temperature chevrons 281 and 462, phone 661, camera 770, … 880, browser 1040, Bluetooth 1150, Toybox 1262, volume 1547. Rectified; the phone and volume positions agree with the native captures to within 1 px.

**Status strip:**
- 60 px (**5%**), drawn over the map, items centred at y 30.
- Over the car panel: range or % and a battery icon ending at about x 718.
- 2024.14+ order: lock 756, profile 826–1025, HomeLink + "Activate" 1094–1241, Wi-Fi about 1320, time 1373–1437, weather 1470–1560, airbag badge 1780–1905.
- Text about 24 px, medium.

**Car panel:**
- x 0–740 (**38.5%** of the width), y 0–1100. No divider.
- Light #f4f4f6 (the photo reads 240); dark #070707.

**Windowed browser card (2024.32+ toolbar, light):**
- Card: x 740–1920, y 60–1100. Square corners, a 7 px soft shadow on the left, #ededef.
- Grab handle: 160×5 at 1249,70.
- Toolbar: y 60–179. Centres at y 130:
  - expand 790, back 870 (#848484), forward 950 (#c4c4c4, disabled)
  - URL field 1000,100 → 1740,160, with a 2 px #a9aaab border, lock icon, host text about 21 px #202124, reload at about 1710
  - star 1790, bookmarks 1870
- No tabs and no close button; you close it by swiping the handle.

**Theater band:**
- y 0–60, #000.
- Handle: 160×5 at x 879.
  - settled: y 10, #272727
  - at launch: y 17, #555, with "Swipe down to dismiss" below it (#eaeaea, about 21 px)
- 2024–25 photos also show:
  - on the left, minimize (x ≈ 30) and back (x ≈ 88)
  - on the right, range (≈ 1783–1837) and battery (≈ 1855–1890)
- No status strip, car panel or dock.

**Type and icons:**
- Tesla's UI face is its own grotesque, Universal Sans, which is proprietary. The demo uses the site's Inter stand-in.
- The dock uses full-colour tiles and flat grey system glyphs.
- The browser toolbar uses thin, roughly 2 px line icons in Chrome's Material style.

**Corners:** the active area has rounded corners of **≈ 18 px** (measured on the photo's lit top corners).

## The cabin photo

- **Chosen:** `research/photos/unsplash-ziontech-u4FO_unYC8I.jpg`, "a car dashboard with a laptop on it" by I'M ZION, Unsplash License, 5512×4410, sRGB.
- **Model and UI:** a Model Y (pre-Juniper) seen from the back seat, near-frontal, with the screen lit in the light Controls view.
- **Why this one:**
  - dark cabin surround for hero text
  - the real UI is crisp enough to keep
  - it holds 4K
  - it crops well to phones
  - it is a different shoot from the lead's "Built for MCU2 and MCU3" photo (Bram Van Oost)
- The runners-up are ranked in `research/photos/candidates.json`.

**Corners, measured:**
- **Method:**
  - `tools/fit_corners.py` edge-fits the **lit UI region**, from the panel's (0,0) to (1920,1100).
  - For each side it takes 80 profiles across the edge, finds the sub-pixel gradient peak, fits a line (two-pass outlier rejection) and intersects the lines.
  - Residuals per side: 0.12 / 0.14 / 0.10 / 0.14 px rms.
- **Why the bottom is inferred:** the dock is black on black glass, so the bottom edge can't be seen. The homography from those four corners (the dock top is y 1100) extends to y 1200.
- **Checks on the homography:**
  - the rectified dock's phone (661) and volume (1547) icons match the native captures within 1 px
  - icon centres sit at y 1148–1150
  - the car panel's edge falls at x 741.5
- **Coordinates:** CSS edge coordinates (pixel i spans [i, i+1]), in the original photo:

| Corner | x | y |
|---|---|---|
| TL | 2117.34 | 1737.15 |
| TR | 3447.24 | 1735.77 |
| BR | 3455.69 | 2568.08 |
| BL | 2112.84 | 2566.69 |

  The shipped photo is cropped to y 360–4000, so `src/demo/photo.ts` has y − 360.

**Photo tone:**
- The UI white reads 237–241, neutral.
- The dock black reads R/G/B 17/16/15.
- The glass reflection sampled 14 px outside the active area runs from about 8 (bottom corners) to about 28 (top, reflecting the windshield).

## How the composite works

- **Panel element:** the live screen is one 1920×1200 element (`src/demo/tesla`). Its background is the photo's **own screen, perspective-rectified** (`screen-ui.webp`), so the car render, status strip and dock are real pixels.
- **No UI pixels in the base photo:** the shipped cabin images have the screen area plus 6 photo px of bezel (the lit UI's lens/JPEG halo) replaced with dark glass, a Coons patch of the bezel's own colour sampled 18 panel px outside, feathered over 4 px (`tools/prep_hero.py`, `blackout`). The real UI reaches the page only through the rectified panel, so an anti-aliasing seam at the panel edge can only show dark glass. This fixed a visible light hairline around the frame (seen on a Retina Mac).
- **Live parts on top:**
  - the browser card
  - the Theater band
  - the browser page area, holding **the real Dashcast client**: `Web/src` markup and CSS, scoped with a `dm-` prefix, at CSS size = page px / 1.53
  - the streamed macOS desktop, letterboxed by the client's own `layout()` rule
- **Perspective:**
  - the panel gets `matrix3d` from the four corners (square→quad homography, `geometry.ts`)
  - the matrix is recomputed from the photo's *rendered* placement on every resize
  - the placement is cover-fit, zoomed toward the screen on narrow hosts
- **Glass:** the reflection field sampled from the bezel is added with `mix-blend-mode: screen`, but only over the live regions (the real-pixel regions already contain it).
- **Glow:** a faint emissive glow in panel space, so it follows the perspective.
- **The film:** frames are drawn from an off-DOM `<video>` into a canvas on the tier's frame clock, like the real client's canvas.
- **Mirror mode:** shows the Mac's own 1512×982 screen, pillarboxed, with its notch-height menu bar. The app's native window capture isn't used: it reads "WebCodecs", which contradicts MCU2's Compatibility mode here.
- **Modes follow the tier:** MCU2 is shown in Compatibility mode, i.e. `http://203.0.113.77` with Chromium's "⚠ Not secure" chip, WebRTC, and the client's WebRTC stats rows (`rtc H264`, `webrtc · H264`; Chrome hides `decoderImplementation`, confirmed headless). MCU3 is shown in Secure mode, i.e. `car.yourdomain.com` with the 2026 tune chip, WebCodecs and HEVC. HEVC is only possible over WebCodecs.
- **No Apple marks:** the menu bar starts with the bold app name.
- **Chrome gotcha:** `will-change: transform` on the desktop windows under the panel's `matrix3d` drops their rounded clip and shadow at small raster scales, so the windows don't use it.
- **Straight-on view:** the four corners are interpolated to a flat, bezelled rect.

**Seam, checked headless (`harness/seam.mjs` + `seam.py`):** the panel is painted black, and a ring ±2 device px across its rounded edge is compared with the bezel 4–8 px outside. Hero and section framing, 1512/1920/3840/390 wide, DPR 1/2/3, plus mid Cabin↔Screen morph and mid Theater grow (30 renders).

| | Ring max luminance | Bezel max |
|---|---|---|
| Before (photo still had its UI) | 94–190 | 29–108 |
| After | 26–29 at rest (≤ bezel everywhere); 65–67 mid-morph (bezel 66–68) | 28–31 |

**Alignment, checked headless (`harness/align.mjs` + `align.py`; measured on the original lit photo, before the blackout):**
- **Method:** the photo's own lit edges are compared with the composited panel painted solid, sub-pixel, on 9 profiles per side.
- **Results:**

| Viewport | Screen width (CSS px) | Mean offset per side (CSS px) |
|---|---|---|
| 1512×945@2 | 539 | ≤ 0.17 |
| 1920×1080 | 685 | ≤ 0.31 |
| 390×844@3 | 348 | ≤ 0.30 |
| 820×1180@2 | 503 | ≤ 0.37 |
| 1180×820@2 | 491 | ≤ 0.07 |
| 3840×2160 | 1369 | ≤ 0.33 |

- The worst single profile is 0.85 px, at 4K, on the webp-compressed photo.
- A half-pixel convention bug (index vs edge coordinates) was found this way and fixed.

## The demo

**Hero** (`story="loop"`, the default with `framing="hero"`): opens on the payoff and loops it calmly every 10 s. Theater, the desktop streaming, the film playing; Safari is dragged out and back and its page scrolled down and up.

**`#demo` story** (30 s loop, GSAP; `src/demo/screen.ts`):

| Time | What happens |
|---|---|
| 0 | Windowed browser: the Dashcast page, "Connecting…" |
| 1.2 | "Waiting for Mac" |
| 2.4 | The client's fullscreen button, which shows its real "Fullscreen isn't available here" hint |
| 3.7 | "Open in Theater mode"; Theater grows out of the card |
| 4.5 | "Swipe down to dismiss" and "Connecting…" again (the page reloaded) |
| 6.5 | First frame behind the veil |
| 7.5 | Tap to start; the tap is also a click, so the pointer jumps there |
| 9 | Drag Safari by its toolbar |
| 11.8 | Two-finger scroll (natural) |
| 14.6 | Play the film |
| 15.9 | Auto switches to Cinema; the "Sound through the car speakers" cue appears |
| 26.6 | The stream ends and Theater is swiped away, back to frame 0 |

**Timing and fidelity:**
- The stream only updates on the tier's frame clock: 30 fps for MCU2, 60 fps for MCU3.
- MCU2 is also slightly soft, a 1242×736 frame upscaled.

**Controls in `#demo`:**
- Cabin / Screen: the four corners morph between the two views.
- Extend / Mirror.
- MCU2 (720p30 H.264) / MCU3 (1080p60 HEVC).
- Show/Hide stats: the real overlay rows, with local-test values.
- Replay.
- Touch: tap = click (it moves the pointer), drag moves windows, the wheel scrolls the article, and tapping the film plays or pauses it.

**Other modes:**
- **Reduced motion:** a static settled frame, with no timeline and no timers.
- **`?capture=1`:** a 10 s seamless loop plus `window.__dashcastCapture.seek(t)` for frame-exact recording.

## Open questions

- **Theater `innerHeight` in a real car:** 745 CSS is expected, not verified.
- **MCU2's browser engine:** whether MCU2 is on Chromium 148 / DPR 1.53, or older, is undocumented.
- **Theater band icons:** the band's minimize/back/range icons may auto-hide; the 2023 capture shows only the handle. The demo shows them.
- **Day/Night:** not offered. The only real, licensable UI pixels are in the photo's light theme, and a dark car panel would have to be invented.
