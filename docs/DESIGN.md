# Scribe design system (0.7.2)

One place for every look decision. The code version lives in
`Sources/Scribe/Views/Theme.swift` (`enum Night` + the components below). If you want to change how
Scribe looks, change it there and every screen follows. Never type a color or a size straight into a
screen: pick a token from this page.

Two themes, same shapes:

- **Night Sky (dark)**: matte near-black, one lavender accent, a 1 px light line on the top edge of
  cards instead of shadows. Faint stars behind the window.
- **Daylight (light)**: cool paper-white, a softer lavender, soft shadows instead of the top line,
  only five tiny sparkles in the background (no dots, no glow). It is its own design, not dark mode
  with the colors flipped.

Scribe follows the Mac (System Settings › Appearance). Settings › General can force Light or Dark.

Rules of taste: minimal, cozy, matte. Lavender is the only accent. Coral means "recording" and
nothing else. Capsule shapes (pill bars) and the four-point sparkle are the brand shapes: use the
sparkle sparingly. No Liquid Glass, no neon, no gradients everywhere (only the wave, the primary
button, the record button, the tab underline and the toggle).

---

## 1. Colors

Hex values, light first, then dark. "@ 0.08" means 8 % see-through.

| Token | What it is for | Light (Daylight) | Dark (Night Sky) |
|---|---|---|---|
| `canvas` | window background | `#F6F5FA` | `#0E0E11` |
| `rail` | left icon rail | `#EFEEF5` | `#09090B` |
| `surface` | cards | `#FFFFFF` | `#16161A` |
| `raised` | popovers, secondary buttons | `#FFFFFF` | `#1D1D23` |
| `well` | sunk areas: text fields, segmented track | `#F1F0F6` | `#111114` |
| `hover` | hover tint on rows and ghost buttons | `#1E1A3C` @ 0.045 | `#FFFFFF` @ 0.04 |
| `line` | card borders, dividers | `#1E1A3C` @ 0.08 | `#FFFFFF` @ 0.065 |
| `line2` | control borders | `#1E1A3C` @ 0.13 | `#FFFFFF` @ 0.10 |
| `highlight` | 1 px top edge on cards | none (0) | `#FFFFFF` @ 0.04 |
| `text` | main text | `#1C1B29` | `#ECEBF5` |
| `text2` | descriptions | `#535166` | `#A9A8BC` |
| `text3` | dates, counts, captions | `#6B6980` | `#85849A` |
| `accent` | links, selected icons, checkmarks | `#5F5AD0` | `#A3A0FB` |
| `accentTop` → `accentBottom` | the lavender gradient | `#7C78E2` → `#6863D6` | `#BABCFF` → `#8680F6` |
| `accentSoft` | selected row / pill fill | `#6560D4` @ 0.09 | `#A3A0FB` @ 0.14 |
| `onAccent` | text on the accent | `#FFFFFF` | `#0D0C1A` |
| `star` | sparkles | `#A8A3EC` | `#C9CAFF` |
| `live` | RECORDING ONLY (dot, timer, stop button) | `#D3424F` | `#F2878E` |
| `liveSoft` | halo behind live things | `#D3424F` @ 0.10 | `#F2878E` @ 0.14 |
| `warn` | a failed step | `#A15C12` | `#F4BE93` |
| `ok` | success | `#267A60` | `#8FD9C2` |
| `shadow` | card shadow | `#1E1A3C` @ 0.07 | none |

Speaker avatar colors (same in both themes, dark text on top): `#BABCFF`, `#8FD9C2`, `#F4BE93`,
`#9CCBFF`, `#E9A9D0`, `#D7D98E`.

The dictation capsule (the little pill that floats while you talk) is always dark, in both themes:
`#1E1E22` → `#09090B`, lavender `#BABCFF` → `#8680F6`, coral `#F2878E`.

**Contrast (checked by the CI self-test, WCAG ratio, 4.5 = readable small text):**
light: text 15.6, text2 7.7, text3 4.9 on canvas / 5.3 on cards, accent 5.4, white on accent 5.4,
coral dot 4.5. Dark: text3 5.3, accent 7.7.

## 2. Type

Font: **Manrope** (bundled, free license), falls back to the system font.

| Token | Size / weight | Use |
|---|---|---|
| `nightDisplay` | 17 / 650 | page title ("Good evening", "Meetings") |
| `nightTitle` | 14 / 650 | sheet and dialog titles |
| `nightHeadline` | 13 / 600 | row titles, card titles, tabs |
| `nightBody` | 13 / 460 | normal text |
| `nightReading` | 13.5 / 460 | notes and transcript (long reading) |
| `nightSecondary` | 12 / 460 | the line under a title |
| `nightSmallStrong` | 12 / 600 | short status lines |
| `nightMeta` | 11 / 550 | dates, counts, captions |
| `nightLabel` | 10.5 / 700, UPPERCASE, +0.7 spacing | section labels |
| `nightKeycap` | 11.5 / 700 | keyboard keys |
| `nightButton` | 12.5 / 600 | buttons, segmented control |

Icons (SF Symbols): `nightIcon(size, weight)` with **small 10**, **regular 12**, **large 14**,
weight medium (semibold inside buttons).

## 3. Space

A 4-point scale. Only use these numbers: **4, 8, 12, 16, 20, 24, 32** (`Night.s4` … `Night.s32`).

| Token | Value | Where |
|---|---|---|
| `gutterLeading` / `gutterTrailing` | 20 / 18 | page edges |
| `cardGap` | 12 | between cards |
| `cardPadding` | 14 | inside cards |
| `rowPaddingH` / `rowPaddingV` | 12 / 8 | inside list rows |

## 4. Sizes

| Token | Value |
|---|---|
| `controlHeight` (buttons, search, segmented) | 28 |
| `controlHeightSmall` (keycaps, chips) | 24 |
| `iconButton` | 26 × 26 |
| `switchSize` (toggle) | 30 × 18 |
| `rowHeight` (sidebar and menu rows) | 30 |
| `avatar` / `avatarSmall` | 22 / 18 |
| `railWidth` (left icon rail) | 52 |
| `meetingsListWidth` | 230 |
| `settingsListWidth` | 124 |
| `headerHeight` (page header) | 52 |

## 5. Corners

| Token | Value |
|---|---|
| `rWindow` | 12 |
| `rCard` | 12 |
| `rSheet` | 14 |
| `rPill` | 9 |
| `rRow` (list rows, sidebar items, wave tiles) | 8 |
| `rControl` (buttons, fields) | 7 |
| `rSegmentOuter` / `rSegment` | 8 / 6 |
| `rKey` | 6 |

Always "continuous" corners (the smooth Apple kind).

## 6. Borders and shadows

- Cards: `surface` fill + 1 px `line` border. Dark adds the 1 px `highlight` on the top edge;
  light adds a soft shadow (`shadow`, blur 6, 1 px down).
- Controls: 1 px `line2` border.
- Dividers: 1 px `line`.

## 7. Motion

Nothing bounces.

| Token | Value | Use |
|---|---|---|
| `fast` | ease-out 0.12 s | hover, pressed |
| `base` | ease-in-out 0.2 s | show/hide, selection, lists changing |
| `spring` | response 0.3, damping 0.9 | moving the selection pill, tabs |

## 8. Components

All in `Theme.swift`, `Brand/Controls.swift`, `Brand/CapsuleBars.swift`, `Brand/Sparkle.swift`.

| Component | Code | Looks like |
|---|---|---|
| Card | `NightCardBackground`, `.nightCard()` | surface, 12 corners, border, top line (dark) or shadow (light) |
| Row | `NightRowBackground`, `ListRow` | 8 corners; hover = `hover`, selected = `accentSoft` |
| Primary button | `.buttonStyle(.nightPrimary)` | lavender gradient, `onAccent` text, 28 tall |
| Secondary button | `.nightSecondary` | `raised` + `line2` border |
| Ghost button | `.nightGhost` | text only; `hover` tint on hover |
| Icon button | `NightIconButtonStyle` | 26 square, raised, border, hover tint |
| Toggle | `.toggleStyle(.night)` / `NightSwitch` | 30 × 18 capsule, lavender when on |
| Segmented control | `NightSegmented` | `well` track, raised selected segment, no accent |
| Tabs | `NightTabs` | headline text, 3 px lavender capsule underline |
| Section header | `SectionLabel` | 7 px sparkle + UPPERCASE `nightLabel` in `text3` |
| Page header | `PageHeader` | `nightDisplay` title + `text3` subtitle, 52 tall |
| Sidebar item | `NightSidebarItem` | 30 tall, sparkle on the selected one, hover tint |
| Capsule bars | `CapsuleBars`, `WaveTile` | the icon's sound wave; bars settle to dots at rest |
| Empty state | `CozyEmptyState` | small glowing sparkle, idle dots, one headline, one line, one button |
| Stat tile | `StatTile` (Home) | icon on `accentSoft`, number, caption |
| Record button | `RecordButton` | lavender circle + mic; coral with a white square while recording |
| Live chip | `LiveChip` | coral dot + timer on `liveSoft` |
| Search field | `NightSearchField` | `well`, 28 tall, ⌘K hint |

## 9. The Home dashboard

Top to bottom: page header (greeting, date, search, Record) → two cards (Start a meeting, Dictate
anywhere), 84 tall → stat tiles (meetings this week, time recorded, words today, voices known) →
meetings card (tabs Meetings / This week, rows grouped under Today / Yesterday / This week /
Earlier, right-click to Rename or Delete) next to Recent dictations (copy button appears on hover).

## 10. App icon

`Resources/AppIcon.icon` (made by `scripts/make_icon_composer.py`), for macOS 26:

- **Light / default**: warm paper tile `#FFFDF9` → `#ECE4D8`, indigo-lavender wave
  `#7074EA` → `#3C3AA4`, faint lavender sparkles.
- **Dark**: near-black tile `#1E1E22` → `#060608`, lavender wave `#BABCFF` → `#8680F6`, bright sparkles.
- **Tinted / Clear**: white wave and white sparkles; macOS adds the glass and the tint.

Older macOS uses `Resources/Assets.xcassets/AppIcon.appiconset` (the dark one, `scripts/make_icon.py`).
