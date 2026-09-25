# Licenses

## Site lead — highlight photos

Originals in `research/tesla-web/refs/photos/` (git-ignored). Shipped derivatives in `public/media/` (`<prefix>-960/1600/2400` and `<prefix>-p750/p1125`, `.avif` + `.webp`). All three were checked as free (not Unsplash+/premium) on 2026-09-24. Every photo shows a Tesla interior or a Tesla, and none comes from the demo cabin's shoot (I'M ZION). The Touch gesture art is our own drawing. The Sound and MCU visuals reuse the demo's licensed assets, and the car-office scene is a Bram Van Oost Model 3 interior (see the Demo section below).

| slot | file prefix | photographer | source page URL | licence |
|---|---|---|---|---|
| Extend or mirror | `extend` | [Priscilla Du Preez](https://unsplash.com/@priscilladupreez) | https://unsplash.com/photos/a-car-dashboard-with-a-monitor-and-steering-wheel-518PH1Y_1EI | Unsplash License |
| Band: “Nothing to install in the car.” | `mcu` | [Bram Van Oost](https://unsplash.com/@ort) | https://unsplash.com/photos/the-interior-of-a-car-with-a-laptop-on-the-dashboard-1tm9Rkp_43Q | Unsplash License |
| Download (closing section + footer) | `charge` | [Prometheus](https://unsplash.com/@iamateapot) | https://unsplash.com/photos/a-group-of-cars-parked-in-a-parking-lot-at-night-OcFDX9_kfLg | Unsplash License |

## Site lead — fonts

None shipped. The site uses the viewer's system Helvetica / Helvetica Neue, falling back to Arial. Tesla's Universal Sans is proprietary and is not used.

## Site lead — icons

The favicons and apple-touch-icon in `public/` are cut from Dashcast's own app icon (`Design/icon/AppIcon-1024.png`). The GitHub mark in the nav links to GitHub, per GitHub's logo guidelines.

## Demo

Originals in `research/photos/` (the ranked shortlist is `research/photos/candidates.json`). Shipped files in `public/demo/`. Unsplash picks were checked through the Unsplash API as free (`premium` and `plus` both false) on 2026-09-24. Third-party screenshots of Tesla's UI in `research/display/refs/` are measurement references only (git-ignored, never shipped).

| use | shipped files | author | source page URL | licence |
|---|---|---|---|---|
| Cabin photo (hero and `#demo`) | `cabin-1600/2560/3840/5504.webp` (cropped to y 360–4000; the screen area is retouched to dark glass interpolated from the photo's own bezel); `screen-ui.webp` (the photo's own screen, perspective-rectified to 1920×1200); `screen-glare.png` (reflection field sampled from the photo's bezel) | [I'M ZION](https://unsplash.com/@ziontech) | https://unsplash.com/photos/a-car-dashboard-with-a-laptop-on-it-u4FO_unYC8I | Unsplash License |
| “Your office, anywhere” photo (`#office`) | `office-1400/2000/2700.webp` (cropped to x 150–2850, y 560–2020; a thin strip of dash retouched in beside the screen, which the drawn swivel uncovers); `office-screen-ui.webp` (the photo’s own screen, rectified). The board, the MacBook and the swivel are our drawing in the photo’s perspective; the Mac displays show our own render and the app’s window capture | [Bram Van Oost](https://unsplash.com/@ort) | https://unsplash.com/photos/black-car-interior-4xM5cytsdMo | Unsplash License |
| Film in the QuickTime window | `clip.mp4`, `clip.webm`, `clip-poster.jpg` (10 s loop from 1.0–11.6 s, 960×540, no audio) | Mixkit | https://mixkit.co/free-stock-video/boats-and-motorboats-sailing-along-a-coastline-during-sunset-40074/ | Mixkit Stock Video Free License |

Every streamed Mac desktop uses the brand wallpaper `public/shots/wallpaper.jpg`, read-only from the screenshots agent (see its rows). The car client UI inside the demo is Dashcast's own (`Web/src/`), and the macOS-style desktop is drawn in CSS/SVG: no Apple wallpaper, icon or font files are shipped.
