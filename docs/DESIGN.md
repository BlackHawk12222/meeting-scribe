# Scribe design system (0.7.3 "Poster")

One place for every look decision. The code version lives in
`Sources/Scribe/Views/Theme.swift` (`enum Night`, the type scale, cards and buttons) and
`Sources/Scribe/Views/Brand/Poster.swift` (poster tiles, mini charts, heatmap, app share bar, chips).
Change a value there and every screen follows. Never type a color or size into a screen.

Poster in one line: flat white (or near-black) pages, hairline borders, one black Record pill,
and color only in the big poster tiles with huge bold numbers. No gradients, no glow, no
sparkles, no starfield, no shadows on cards.

Scribe follows the Mac (System Settings › Appearance). Settings › General › Appearance can force
Light or Dark.

## 1. Colors

| Token | Use | Light | Dark |
|---|---|---|---|
| `canvas`, `surface` | window and card background | `#FFFFFF` | `#111112` |
| `rail` | icon rail, meetings list, settings list | `#F7F7F8` | `#0B0B0C` |
| `raised` | popovers, sheets | `#FFFFFF` | `#1A1A1C` |
| `well` | fields, chips | `#F7F7F8` | `#161618` |
| `hover` | hover fill | `#F5F5F7` | `#19191B` |
| `selected` | selected rail item / row / segment | `#EDEDF0` | `#232326` |
| `line` | hairline borders and dividers | `#E8E8EB` | `#232326` |
| `line2` | control borders | `#DADADF` | `#2E2E32` |
| `text` | main text | `#111113` | `#EDEDF0` |
| `text2` | secondary text | `#6B6B73` | `#9A9AA3` |
| `text3` | captions, times (≥ 4.5:1 on canvas, surface, rail, well) | `#707078` | `#86868E` |
| `primary` / `onPrimary` | Record pill, primary buttons | `#111113` / white | `#EDEDF0` / `#111113` |
| `accent` | switches, links | `#5B57D9` | `#8E8BF5` |
| `live` | recording dot only | `#E5484D` | `#E5484D` |

Poster tiles (same in both themes, white text): indigo `#5B57D9`, coral `#F2685B`,
green `#1FA463`, black `#141416` (the black tile gets a `#2E2E32` hairline in dark mode).

App colors ("Where you talk", history dots), by rank of words: `#F5B83D`, `#34C77B`, `#3D8BFD`,
`#36B5D9`, `#5B57D9`, `#F2685B`; everything else and pre-0.7.3 dictations ("Other") grey.

Heatmap, empty → busiest: light `#EEEEF3 #D6D4FB #ABA7F5 #7C77EB #5B57D9`,
dark `#1E1E22 #2E2B5C #433E9A #625CD6 #8E8BF5`.

Contrast (WCAG, checked by the targeted self-test): `text` ≥ 7, `text2` and `text3` ≥ 4.5 on
`canvas`/`surface` (and `text3` also on `rail`/`well`). `text3` is light 4.91 on white / 4.59 on
`#F7F7F8`, dark 5.23 on `#111112` / 5.45 on `#0B0B0C`, and stays a step quieter than `text2`.
No shadows in either mode (`shadow` alpha 0, radius 0); no inner highlight.

Speaker avatars (white letter): `#5B57D9 #F2685B #1FA463 #F5B83D #3D8BFD #36B5D9`; an unnamed
speaker is grey.

## 2. Type

The system font (SF Pro). Body text is 14–15 pt; nothing smaller than 12.5 pt except
capsule details.

| Token | Size / weight | Use |
|---|---|---|
| `nightDisplay` | 15 / semibold | top bar page title |
| `pageTitle` | 24 / semibold | meeting title, settings pane title |
| `nightTitle` | 17 / semibold | sheet titles |
| `nightHeadline` | 14 / medium | row titles |
| `nightBody` | 14 / regular | normal text |
| `nightReading` | 15 / regular | dictations, notes, transcript |
| `nightSecondary` | 13 / regular | descriptions, chips |
| `nightMeta` | 12.5 / regular | captions |
| `nightLabel` | 12.5 / semibold, sentence case | section headers (with a hairline under) |
| `posterNumber` | 48–72 / bold, tight tracking | poster tile numbers |

## 3. Shape and size

Radius: controls 6, cards 8, poster tiles 10, capsule 17, rail items 8. Icon rail 68 pt (was 46):
44 pt items with 20 pt icons; the traffic lights, then the 34 pt Scribe logo (light/dark like the
Dock icon) on top; the 30 pt round profile avatar above Settings at the bottom.
Top bar 52 pt (title, 210 pt search with ⌘K, Record pill 28 pt). Settings list 196 pt.
Meetings list 300 pt. Poster tiles: Home 186 pt tall, other pages 120–132 pt.

## 4. Screens

- **Home**: tiles (words this week + daily bars, streak + last 7 days, words per minute + ring),
  last 26 weeks heatmap, "Where you talk", Latest.
- **Dictation**: tiles (today, average speed, top app), history with app filter chips, Dictionary,
  Style (Natural / Polished / Exact), Shortcut (the real hold key; double-tap = hands-free).
- **Meetings**: list (This week / Earlier) + detail: tiles (duration, speakers, action items),
  "speaker needs a name" notice, summary, action items with owner chips, Who talked.
- **People**: unknown-voice banner, tiles, person cards with voice strength.
- **Settings**: General, Dictation, Meetings, Vocabulary, Models, Updates.
- **Profile** (the avatar in the rail): avatar (photo or initial), display name, member since,
  add/change/remove photo; tiles (words dictated all time, streak, words per minute, meetings);
  links to Shortcut & style, My voice, Appearance, Updates. Name and photo stay on this Mac
  (`profile.json`, `profile-photo.png`).
- **Name voices** (Meeting › Name voices): waveform timeline with speaker bands, ruler scrub,
  playhead, Space = play/pause (not while typing), drag to select, drag edges / ±0.1 s to trim,
  zoom 1–8×; assign to a person chip or a typed name, Assign all to…; transcript updates live;
  Undo (⌘Z), Save (⌘↩). Save re-teaches voiceprints (confirmed audio weighted ×2) and adds typed
  names to Vocabulary. Meetings only (dictations don't keep audio). No model retraining.
- **Learn from my fixes**: edit a dictation (History › pencil) or a transcript line (pencil);
  the word diff learns a fix seen twice as a replacement, a capitalized name after one fix (also
  into Vocabulary); black "Learned: X → Y" toast with Undo; Settings › Vocabulary › Learned from
  your fixes lists and removes them. Settings › Models › Corrections: opt-in (off) local audio +
  corrected-text pairs for a future fine-tune, with a count and Delete all.

- **Recording-consent notice** (0.7.3.1): when a meeting recording starts, a hairline card on top
  of the live meeting view: indigo `person.2` tile, "Let everyone know you're recording. Some
  places require everyone's OK.", "Don't show again" (UserDefaults `consentReminderHidden`) and ×
  (this meeting only). Non-blocking; the recording is already running.
- **Credits & licenses** (0.7.3.1, Settings › General › About › Open): Legal (Privacy Policy,
  Terms of Use: "Coming soon" chips until `LegalLinks` has URLs), then Speech models, Open-source
  code, Fonts and design, Other; each row has version, license chip, links and View license.
  Data: `Resources/Licenses/licenses.json` + full texts; build.sh copies Package.resolved in and
  `scripts/check_licenses.py` fails the build if a resolved package has no entry.

## 5. Data rules

Every number is real. Dictation counts come from the ledger in
`~/Library/Application Support/Scribe/dictation-stats.json` (words, seconds, dictations and words
per app, per day; no text). "This week" is the sum of the current calendar week's days.
Words per minute = words ÷ minutes of speech over the last 30 days. Streak = days in a row with a
dictation, ending today (or yesterday until today has one). "about N× typing" compares with an
assumed 40 wpm typist. Voice strength thresholds are in `Views/PeopleView.swift`:
Strong = 5+ meetings, or enrollment + 2 meetings, or 30+ min of confirmed talk; Good = 2+
meetings, or enrollment, or 5+ min; Learning = less.

## 6. The dictation capsule

Always black `#141416` with a 1 px white @ 12 % edge, 34 pt thick, radius 17, in both themes.
States: Listening (red dot, white waveform, timer), Thinking (three dots), Done (green check +
"Pasted into <App>"), Problem (red cross + message + "Open Settings" when there is a fix).
Against a left/right screen edge it stands up: 34 pt wide, bars run up and down, Done/Problem
show the icon and one word ("Done", "Fix"), the full message is the tooltip.
