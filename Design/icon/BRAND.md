VERSION: light-glass

# Dashcast: icon & brand notes

> STATUS: FINAL light-glass icon (2026-09-24). Files: `Design/icon/AppIcon-1024.png` and
> `Design/AppIcon.icns`. Hexes are sampled from the final Codex artwork (`concepts/M1.png`).
> The previous dark "cast to the dash" set is retired and lives in `archive-dark/`.

## Concept: "Same picture, two screens"

A bright white frosted-glass tile carries one crisp coloured mark:

- **The car display:** a wide rounded display (≈2.2:1) filled with a flat electric-blue → cyan
  gradient.
- **The Mac:** a smaller MacBook-proportioned (16:10) pane of frosted white glass. It floats in
  front of the display's lower-left corner and sticks out below and to the left.
- **The link between them:** inside the Mac pane is the same blue → cyan screen. The Mac's
  picture is the picture on the car's wide display.

The look is layered glass, like Apple's Freeform and Preview icons. It's flat-ish with a soft
sheen. Nothing glows, and there is no neon or photographic gloss. The small pane sits at the
lower-left, not on the top edge, so the silhouette never reads as a Finder folder tab.

## Palette

| Token            | Hex       | Use                                                             |
|------------------|-----------|-----------------------------------------------------------------|
| `glass-white`    | `#FFFFFF` | tile top / primary light surface                                |
| `glass-mist`     | `#EDF2F8` | tile bottom; page / DMG canvas base (vertical white → mist)     |
| `glass-mid`      | `#F6F8FB` | mid-tile tone; large quiet surfaces                             |
| `frost`          | `#EAF1FA` | the frosted Mac pane (white glass with a faint blue tint)       |
| `frost-edge`     | `#D5DCE6` | hairlines, glass edges, dividers                                |
| `shadow-cool`    | `#D1D9E4` | soft contact shadow under raised panes (or `#1C2330` at 8–18%)  |
| `accent-blue`    | `#0872FE` | mark gradient start (left): crisp electric blue                 |
| `accent-azure`   | `#15ABFE` | gradient midpoint                                               |
| `accent-cyan`    | `#18D3FD` | mark gradient end (right)                                       |
| `graphite`       | `#1C2330` | dark neutral: primary text on light, bezels if ever needed      |
| `slate`          | `#5B6678` | secondary text                                                  |
| `slate-light`    | `#8A96AB` | tertiary text / small-size pane outline                         |

- **Mark gradient:** `#0872FE → #15ABFE → #18D3FD`, running left → right with a slight
  upward tilt. It's flat and matte, with no glow.
- **Tile:** a vertical gradient from `#FFFFFF` down to `#EDF2F8`, with a faint cool-grey edge.
- **Shadows:** soft, neutral and cool. No coloured shadows or glows.

## Key shapes (fractions of the icon body)

1. **Wide display:** a rounded rectangle about 2.2:1, spanning about 12–88% of the width and
   27–61% of the height. Corner radius is about 9% of its height. It's filled with the mark
   gradient and carries a faint soft shadow.
2. **Mac pane:** a 16:10 frosted-white rounded rectangle, about 50% of the display's width. It
   overlaps the display's lower-left corner and extends to about 71% of the height. It has a
   crisp light edge and a soft `shadow-cool` drop shadow.
3. **Inner screen:** a blue → cyan rectangle inside the pane with an even white border, the same
   picture as the wide display.

## Icon construction

- **Artwork:** generated with Codex image gen via `codex-design-handoff` → `brandkit`. The
  prompts are in `work/prompts/` (`common-light.txt`, `L*`, `M*`, `S*`).
- **Post-processing** is done by `work/iconkit.py` and `work/build.sh`:
  - **Mask:** Apple's continuous-corner squircle, an 824 px body on a 1024 canvas with a 185.4 px
    radius. The art is zoomed ×1.06.
  - **Edge:** a light-tile rim, which is a faint cool-grey edge (heavier toward the bottom) plus a
    white inner sheen at the top.
  - **Shadow:** a baked macOS shadow, 12 px y-offset with a 16 px blur at 32%, plus a 3 px/4 px
    contact shadow at 22%.
  - **Small sizes:** the 16 px and 32 px renders (16@1x, 16@2x, 32@1x) use the simplified
    Codex variant `concepts/S1b.png`. Its mark is bigger, and the Mac pane has a `slate-light`
    outline so the white pane separates from the white tile. They also get a 1 px cool-grey edge
    drawn at that size, so the white tile holds its outline on white backgrounds.
- **Rules:** no text or letters, no Tesla "T" or any other brand mark, and no car or
  steering-wheel clip-art.
