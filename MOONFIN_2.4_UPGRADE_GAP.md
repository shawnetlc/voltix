# Voltix vs Moonfin Core 2.4.0 — Upgrade Gap Report

**Your fork:** `voltix` 1.6.24 (forked from Moonfin **2.2.0**)
**Reference:** `moonfin` **2.4.0**
**Compared:** preferences, settings screens, menu structure — `lib/` only

---

## 1. Why the menus look different

Four changes account for nearly all of it:

**A search box at the top of Settings.** Moonfin 2.4.0 indexes 94 settings leaves and lets you type to jump straight to one. Your panel is a plain list with no search — this is the first thing anyone notices.

**The "Dynamic Content" category is gone upstream.** Moonfin folded *Media Bar*, *Local Previews* and *Seasonal Effects* into **Personalization**, then added two new entries there (*Details Screen*, *Theme Music*). Personalization goes from 5 tiles to 10, and the top-level menu loses a row.

**Grouped card sections instead of a flat list.** Moonfin wraps entries in `adaptiveListSection(...)`. On iOS/macOS that renders as inset grouped rows; yours renders edge-to-edge.

**The panel was split into files.** `settings_side_panel.dart` went from a 4,048-line monolith (yours) to 399 lines plus a `settings/panel/` directory of 28 extracted screens. **This refactor is invisible to users** — but it makes every future merge from upstream dramatically easier, so it's worth adopting for its own sake.

---

## 2. Scale of the gap

| | Count |
|---|---|
| Preferences in Moonfin 2.4.0 missing from your build | **106** |
| Settings screens missing entirely | **9** |
| Moonfin-only enum types | **20** |
| Preferences where your default has drifted from upstream | **23** |
| Your own additions not in upstream | 29 prefs, 3 screens |

---

## 3. Missing features, by user impact

### Tier 1 — whole features users can see are absent

| Feature | Where it lives upstream | What it gives you |
|---|---|---|
| **Settings search** | `panel/settings_search_field.dart`, `panel/settings_search_index.dart` | Type-to-find across all settings |
| **External Home Rows** | `panel/external_lists_screen.dart` (100 KB) | IMDb charts, TMDB lists, Radarr/Sonarr calendars, Seerr discovery rows, custom row wizard |
| **"Since You Watched" rows** | `home_row_toggles_screen.dart` | Up to 5 recommendation rows seeded from a watched item, with source/type/count controls |
| **Rewatch row** | `home_row_toggles_screen.dart` | "Watch again" row + sort and content-type filters |
| **Details Screen category** | `panel/details_screen_settings_screen.dart` | Detail style, blur, opacity, expanded tabs, technical details, recommendation source |
| **Button layout editors** | `panel/detail_buttons_screen.dart`, `panel/osd_buttons_screen.dart`, `lib/preference/button_layout.dart` | Reorder/hide detail and player buttons, per form factor (TV/mobile/desktop) |
| **Playback time layout** | `panel/playback_time_layout_screen.dart` | Six configurable clock slots around the seek bar |
| **Theme Music screen** | `panel/theme_music_screen.dart` | Includes **Loop Theme Music**, which you don't have at all |
| **Games/emulator** | `emulator_cores_screen.dart`, `downloaded_games_screen.dart` | Native libretro backend, core downloads, ROM management |

### Tier 2 — individual settings missing from screens you already have

**Appearance**
- Interface Style (Cupertino vs Material idiom)
- Glass Quality (blur/translucency level)
- OLED Mode (off / subtle / vivid)
- Navbar always expanded

**Audio** — upstream replaced your preset + output-mode pair with a single model
- Audio passthrough mode (disabled / auto / manual) + one-time migration flag
- Downmix to stereo
- Fallback audio language
- Prefer default audio track
- Prefer audio description

**Subtitles**
- Subtitle Mode enum (flagged / always / foreign / forced / none) — you only have a coarse "default to none" boolean
- Fallback subtitle language

**Home screen**
- Next Up max days
- Home rows padding (separate values for modern and classic layouts)
- Merge recent rows by type
- Per-Row Image Type Selection — **see §4, the screen exists in your tree but is unreachable**

**Libraries**
- Group items into collections
- Hide backdrops in libraries
- Alphabetical (A–Z) filter bar
- Per-library scroll direction and group-by (genre / rating / decade / studio)

**Playback**
- Cinema Mode for episodes
- Skip button auto-hide timeout
- Resume last queue on play
- Media segment auto-hide

**Downloads / storage**
- Report downloads as activity
- Image cache limit + Clear image cache — **gone entirely from your build, not relocated**
- Custom download path bookmark

**Live TV**
- Channel sort by (number / name / favourites first)
- EPG mobile view (list / grid)

**Audiobooks** — default speed, sleep preset, extend sleep timer

**Security**
- Allow self-signed certificates

**Parental**
- Apply parental rating cap to recommendations

### Tier 3 — missing enum options

- `LibrarySortBy` — upstream adds `playlistOrder`, `albumArtist`, `album`, `genre`
- `VisualThemeId` / `AppTheme` — missing the 8-bit Hero theme
- `SeerrRowType` — missing `yourWatchlist`
- `HomeSectionType` — missing **25 members**: 6 IMDb rows, 13 TMDB rows, Radarr/Sonarr calendars, rewatch, sinceYouWatched 1–5

---

## 4. Problems in your fork worth fixing regardless

These aren't upstream features — they're defects the comparison exposed.

**Dead screen.** `home_rows_image_type_screen.dart` exists in your tree but is referenced nowhere in `lib/`. The tile that opens it was never wired up, so per-row image type is unreachable. Upstream exposes it at `panel/home_screen_category_screen.dart:162`.

**Hardcoded LAN address in shipping settings.** Account & Security has a "Use Local Test Server" toggle pointing at `http://192.168.0.31:3000/`. That should be a debug-only build flag, not a user-visible switch in a release.

**Admin menu gated on a username substring.** Your check ORs together the admin provider, `currentUser.isAdministrator`, *and* `username.contains('admin')`. Any account whose name merely contains "admin" sees the Administration menu. Upstream gates on `!isTV && isAdminProvider` only. Worth tightening.

**Image cache settings vanished.** Both the limit and the clear action are absent from your build with no replacement anywhere in `lib/ui`.

---

## 5. Default-value drift

23 preferences have different defaults from upstream. Some are deliberate branding (`app_theme_id`, `mediaBarMode`) — but these look like accidental drift and are worth a deliberate decision:

| Preference | Moonfin 2.4.0 | Yours |
|---|---|---|
| `poster_size` | medium | small |
| `pref_home_rows_style` | platform-aware (v1 mobile / v2 desktop) | hard-coded v1 |
| `pref_home_rows_fullscreen` | false | true |
| `trick_play_enabled` | true | false |
| `enableEpisodeRatings` | true | false |
| `enabledRatings` | stars, imdb, tmdb, tomatoes, metacritic | tomatoes, stars |
| `mediaBarTrailerPreview` | true | false |
| `previewAudioEnabled` | true | false |
| `pref_navbar_position` | top | left |
| `pref_use_24_hour_clock` | false | true |
| `pref_prefer_system_ime_keyboard` | includes Apple TV | excludes Apple TV |
| `pref_live_direct` | false | true |
| `pref_syncplay_enabled` | false | true |
| SyncPlay sync thresholds (3 values) | 100 / 5000 / 1000 | 120 / 2500 / 1200 |

---

## 6. Suggested order of work

1. **Adopt the panel refactor first** (`settings/panel/` split). It's user-invisible but every later port becomes a file copy instead of a merge into a 4,000-line file.
2. **Port the preference definitions** — 106 prefs and 20 enums, mostly mechanical, and nothing else works without them.
3. **Tier 1 features**, in this order: settings search → Details Screen category → Theme Music → button layout editors → Since You Watched / Rewatch rows → External Home Rows (biggest, 100 KB) → games/emulator (skip if not wanted).
4. **Tier 2 settings**, screen by screen.
5. **Fix the four fork defects** in §4 — quick wins, independent of any porting.
6. **Decide consciously on each default in §5** rather than inheriting drift.

### Watch out for during the port

- **Audio model conflict.** Upstream collapsed EAC3 JOC / DTS:X / TrueHD JOC into parent toggles plus a passthrough mode, and ships a migration flag (`pref_audio_passthrough_mode_migrated_v1`). You have an extra `truehd` codec member upstream lacks. Reconcile deliberately — a naive port will lose your Atmos handling.
- **`seerrBlockNsfw`** is not missing; you renamed it `jellyseerrBlockNsfw`.
- **`HomeSectionType`** is where your IPTV rows live. Merge the 25 new upstream members without dropping your 6 `iptv*` entries and `recommendations`.
- Your Voltix-only screens (`profile_settings_screen`, `about_screen`, `home_screen_sections_integration_screen`) have no upstream counterpart — keep them and re-attach them to the new panel structure.
