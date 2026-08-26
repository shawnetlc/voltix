# Work Order — Voltix: Settings Panel Refactor + External Home Rows

**Give this whole document to the coding agent.** It contains two work orders. WO-1 must
land and compile before WO-2 starts. Do not interleave them.

---

## 0. Context the agent needs before touching anything

**Project:** `Voltix` — a Flutter fork of Moonfin Core **2.2.0**, currently at app version
1.6.24. Working tree: `C:\Voltix Newest`.

**Reference tree (READ ONLY — never write here):**
`C:\Users\ShawneBedford\OneDrive - TLC - Think Logic Consulting (1)\Desktop\Moonfin-Core-2.4.0\Moonfin-Core-2.4.0`

This is upstream **Moonfin Core 2.4.0**. The goal of both work orders is feature parity
with it. Treat upstream as the specification: when in doubt, match upstream's structure,
naming and behaviour exactly rather than inventing something.

**Rules that apply to both work orders:**

1. **Back up before every file rewrite.** Copy the original to `<name>.bak-<step>` in the
   same folder, or work on a git branch and commit per step. There is no CI here.
2. **`flutter analyze` is the only verification available.** Run it after every step. Do
   not proceed to the next step while it reports errors. Warnings about unused elements
   are acceptable mid-refactor but must be zero at the end of each work order.
3. **Never reorder or "tidy" code you are moving.** These refactors are cut-and-paste.
   Byte-identical moves make the diff reviewable and make future upstream merges possible.
   Reformatting a moved block is a defect, not an improvement.
4. **Voltix has fork-specific code upstream does not have.** Do not delete anything just
   because upstream lacks it. The fork-specific pieces are called out explicitly below.
   If you find something not on the list, stop and report it rather than guessing.
5. **Voltix's design package is `voltix_design`, not `moonfin_design`.** Upstream files
   import `package:moonfin_design/moonfin_design.dart`. When porting, swap to
   `package:voltix_design/voltix_design.dart` and verify each symbol used actually exists
   there. `voltix_design` is a trimmed fork — several upstream design symbols are absent
   (see §1.4). Do not add a dependency on `moonfin_design`.
6. **Report, don't improvise.** If a port needs a symbol that does not exist in Voltix,
   stop, write down what is missing, and either stub it with a clearly-marked `TODO` that
   compiles, or ask. Silent behavioural substitutions are the failure mode to avoid.

---

# WORK ORDER 1 — Settings panel refactor

## 1.1 What this is and why

Voltix's `lib/ui/screens/settings/settings_side_panel.dart` is a **4,013-line monolith**
containing **57 classes**. Upstream 2.4.0 split the same file into a **399-line shell**
plus a `settings/panel/` directory of **28 part files**.

This refactor is **invisible to users**. Its entire value is that every future port from
upstream becomes a file copy instead of a merge into a 4,000-line file. WO-2 and every
tranche after it depend on this landing first.

## 1.2 The mechanism: Dart `part` / `part of`

Upstream does **not** convert the private classes into public ones or add imports. It uses
Dart's `part` directive:

- `settings_side_panel.dart` keeps **every** `import` statement and adds a block of
  `part 'panel/<name>.dart';` directives after them.
- Each extracted file starts with exactly one line: `part of '../settings_side_panel.dart';`
  and then the moved classes verbatim.

Why this matters, and why you must not "improve" on it:

- Library-private identifiers (`_TvSettingsListTile`, `_SectionHeader`, `_PanelEntry`,
  every `_XxxScreen`) stay private and stay visible across all parts. **Zero renames.**
- Part files must have **no imports of their own**. All imports live in the parent file.
  Adding an import to a part file is a compile error — this is your correctness check.
- Order of `part` directives does not affect semantics, but keep upstream's order so the
  files diff cleanly against upstream later.

## 1.3 The split map

Voltix's current file, by line range. Cut each range into the target file, in this order.
Line numbers are from the file as it stands today (4,013 lines) — **re-derive them as you
go**, since each cut shortens the source file.

| Voltix lines | Contents | Target file |
|---|---|---|
| 1–68 | imports | stays in `settings_side_panel.dart` |
| 69–252 | `SettingsSidePanel`, `_SettingsSidePanelState` | stays in `settings_side_panel.dart` |
| 253–460 | `_PanelEntry`, `_PanelEntryTile`, `_TvSettingsListTile`(+State), `_SectionHeader`, `_formatCamelCaseLabel`, `_ensureSettingsTileVisible` | `panel/settings_panel_infra.dart` |
| 461–597 | `_AuthenticationCategoryScreen` | `panel/authentication_category_screen.dart` |
| 598–664 | `_CustomizationCategoryScreen` | `panel/customization_category_screen.dart` |
| 665–844 | `_GeneralStyleScreen`(+State) | `panel/general_style_screen.dart` |
| 845–984 | `_NavigationCategoryScreen`(+State) | `panel/navigation_category_screen.dart` |
| 985–1133 | `_HomeScreenCategoryScreen`(+State) | `panel/home_screen_category_screen.dart` |
| 1134–1193 | `_LibrariesCategoryScreen` | `panel/libraries_category_screen.dart` |
| 1194–1235 | `_PluginCategoryScreen` **(Voltix-only)** | `panel/plugin_category_screen.dart` |
| 1236–1263 | `_SeasonalEffectsScreen` | `panel/seasonal_effects_screen.dart` |
| 1264–1339 | `_IntegrationsScreen`(+State) | `panel/integrations_screen.dart` |
| 1340–1471 | `_PluginScreen`(+State) | `panel/plugin_screen.dart` |
| 1472–1558 | `_MetadataRatingsScreen`(+State) | `panel/metadata_ratings_screen.dart` |
| 1559–1654 | `_OfflineDownloadsScreen`(+State) **(Voltix-only)** | `panel/offline_downloads_screen.dart` |
| 1655–1747 | `_AboutCategoryScreen`, `_CheckForUpdatesTile`(+State) | `panel/about_category_screen.dart` |
| 1748–1963 | `_LicensesScreen`(+State), `_LicenseDetailScreen`(+State), `_LicensePackageData` | `panel/licenses_screen.dart` |
| 1964–2036 | `_PlaybackCategoryScreen` | `panel/playback_category_screen.dart` |
| 2037–2511 | `_VideoPlaybackScreen`, `_ExternalPlayerAppPickerTile`(+State), `_ExternalPlayerAppIcon` | `panel/video_playback_screen.dart` |
| 2512–2894 | `_AudioPreferencesScreen`(+State) | `panel/audio_preferences_screen.dart` |
| 2895–3029 | `_AutomationQueueScreen`(+State) | `panel/automation_queue_screen.dart` |
| 3030–3148 | `_AdvancedOptionsScreen`(+State) | `panel/advanced_options_screen.dart` |
| 3149–3323 | `_SyncPlaySettingsScreen`(+State) | `panel/syncplay_settings_screen.dart` |
| 3324–4013 | `_EditableStringPreferenceTile`, `_DoubleSliderTile`, `_NavbarColorPickerTile`, `_ShuffleContentTypePickerTile`, `_CloudSettingsSyncTile` **(last one Voltix-only)** | `panel/settings_panel_tiles.dart` |

Three target files in the table are **not** in upstream — `plugin_category_screen.dart`,
`offline_downloads_screen.dart`, and the `_CloudSettingsSyncTile` inside
`settings_panel_tiles.dart`. That is expected and correct: these are Voltix features
(the Voltix plugin category, the offline downloads screen, and Azure-blob cloud settings
sync). **Keep them. Do not "align with upstream" by deleting them.**

Upstream also has part files Voltix has no counterpart for yet — `details_screen_settings_screen`,
`theme_music_screen`, `playback_time_layout_screen`, `osd_buttons_screen`,
`detail_buttons_screen`, `external_lists_screen`, `settings_search_field`,
`settings_search_index`. **Do not create these in WO-1.** They belong to WO-2 and to later
tranches. WO-1 moves existing code only.

## 1.4 Symbols upstream uses that Voltix does NOT have

When you open an upstream part file to compare, you will hit these. They are the reason
you cannot simply copy upstream's part files over Voltix's:

| Upstream symbol | Voltix status | What to do in WO-1 |
|---|---|---|
| `adaptiveListSection(children: [...])` | **absent** — `lib/ui/widgets/adaptive/` does not exist in Voltix | Voltix's code wraps tiles in plain `Column`/`ListView` children. Leave Voltix's existing layout code exactly as-is. Do **not** introduce `adaptiveListSection` in WO-1. |
| `SettingsSectionHeader` widget | absent — Voltix has a local `_SectionHeader` with an inline `Padding`+`Text` | Keep Voltix's local `_SectionHeader`. It moves into `settings_panel_infra.dart` unchanged. |
| `buildSettingsLeadingIconShell`, `settingsHeadlineColor`, `settingsTileInvertsOnFocus` | absent | Voltix's `_TvSettingsListTile` does not call them. Nothing to do. |
| `AppUiIdiomResolver` / `InterfaceStyle` | **present** (ported already, at `lib/util/idiom/app_ui_idiom.dart`) but **not read by any UI** | Ignore in WO-1. |
| `showFocusRestoringDialog` | verify — grep before assuming | If absent, WO-2 needs it; note it and move on. |
| `RequestInitialFocus` | **present** at `lib/ui/widgets/focus/request_initial_focus.dart` | Fine. |
| `withCleanSettingsTypography`, `buildSettingsAppBar`, `context.pushSettingsScreen`, `TvFocusHighlight`, `SwitchPreferenceTile`, `EnumPreferenceTile`, `SliderPreferenceTile`, `IntPickerPreferenceTile`, `StringPickerPreferenceTile` | **all present** | Fine. |

## 1.5 Procedure

Do this **one part file at a time**, running `flutter analyze` between each. Do not batch.

For each row of the split map:

1. Create `lib/ui/screens/settings/panel/<target>.dart` containing exactly:
   ```dart
   part of '../settings_side_panel.dart';

   <the moved code, byte-identical>
   ```
2. Delete that exact range from `settings_side_panel.dart`.
3. Add `part 'panel/<target>.dart';` to the part block in `settings_side_panel.dart`
   (after the imports, before `class SettingsSidePanel`).
4. Run `flutter analyze`. Expect **zero** new errors. If you see "undefined name", you cut
   a boundary wrong — restore from backup and re-cut.

After all rows are done:

5. `settings_side_panel.dart` should be roughly **250–420 lines**: imports, the part block,
   `SettingsSidePanel`, `_SettingsSidePanelState`. Nothing else.
6. Confirm **no part file contains an `import` statement**. `grep -n "^import" lib/ui/screens/settings/panel/*.dart` must return nothing.
7. Confirm every part file's first line is `part of '../settings_side_panel.dart';`.
8. Run `flutter analyze` — must be completely clean.
9. **Manual smoke test on device**: open Settings, walk into every category, back out of
   each. The refactor changes no behaviour, so any visual or navigation difference is a bug
   you introduced.

## 1.6 Definition of done for WO-1

- 24 new files under `lib/ui/screens/settings/panel/`.
- `settings_side_panel.dart` under 450 lines.
- `flutter analyze` clean.
- Settings navigates identically to before, verified on device.
- No class renamed, no method body edited, no import added or removed.

---

# WORK ORDER 2 — External Home Rows

**Do not start until WO-1 is merged and `flutter analyze` is clean.**

## 2.1 What this is

Upstream's **External Home Rows** subsystem adds home screen rows sourced from outside the
Jellyfin library: IMDb charts, TMDB charts, Radarr/Sonarr upcoming calendars, Seerr
discovery rows, and a user-defined custom-row wizard (IMDb user lists, IMDb events, TMDB
collections/lists, Letterboxd, MDBList).

Upstream implementation, all of which you will port:

| Upstream file | Size | Role |
|---|---|---|
| `lib/ui/screens/settings/panel/external_lists_screen.dart` | 100 KB, 2,571 lines | All the settings UI. Contains `_ExternalListsScreen`, `_ImdbListsScreen`, `_TmdbListsScreen`, `_UpcomingCalendarsScreen`, `_SeerrListsScreen`, `_SeerrRowSwitchTile`, `_CustomListsScreen`, `_AddEditCustomRowDialog`, `_SettingsTextField` |
| `lib/data/services/custom_external_lists_service.dart` | 10.7 KB | `ImdbExternalListItem` model + `CustomExternalListsService` (fetch, disk cache, sort) |
| `lib/preference/preference_constants.dart` | — | 21 new `HomeSectionType` members + `SeerrRowType.yourWatchlist` |
| `lib/preference/user_preferences.dart` | — | ~30 new preferences |
| `lib/ui/screens/home/home_view_model.dart` | — | visibility gating, row→section matching, loaders, skeletons |
| `lib/data/services/row_data_source.dart` | — | `HomeSectionPluginSource.custom` branch of `loadDynamicSection` |

## 2.2 Hard dependency: the server plugin

**Read this before writing any code.** `CustomExternalListsService` does not scrape IMDb or
call TMDB from the app. It calls the **Moonfin server plugin**:

```
GET {baseUrl}/Moonfin/CustomRows/Items?source=<>&type=<>&params=<json>[&refresh=true]
Authorization: MediaBrowser <device info>, Token="<access token>"
→ { "success": true, "items": [ { name, type, providerIds:{Imdb,Tmdb}, posterUrl, backdropUrl, productionYear, rating, popularity, userRating } ] }
```

Voltix reaches its Jellyfin servers through the Voltix backend proxy at
`voltixstudio.com`. The plugin route namespace on those servers is `/Moonfin/...`
(confirmed: `/Moonfin/Jellyseerr/Config` returns 401 = route exists; `/Voltix/Jellyseerr/Config`
returns 404 = does not).

**Step zero of WO-2:** verify the `CustomRows` controller actually exists on the primary
server, e.g.:

```
curl -i "https://<server>/Moonfin/CustomRows/Items?source=imdb&type=imdb_top_250_movies&params=%7B%7D"
```

- `401` → route exists, auth needed. Good, proceed.
- `404` → **stop**. The server's Moonfin plugin is too old or lacks the CustomRows
  controller. Report this. No amount of client work will make these rows load. Everything
  below still ports cleanly but every row will render empty.

Also confirm the Voltix backend proxy forwards `/Moonfin/CustomRows/*` rather than
stripping or rewriting it.

## 2.3 Port order

Bottom-up. Each step compiles on its own.

### Step 1 — Enum members (`lib/preference/preference_constants.dart`)

Add to `HomeSectionType`, **preserving Voltix's existing 54 members exactly** (Voltix has 6
`iptv*` members and `sinceYouWatched1–5` that upstream orders differently — do not
reorder, do not drop):

```
imdbTop250Movies('imdb_top_250_movies'),
imdbTop250TvShows('imdb_top_250_tv_shows'),
imdbMostPopularMovies('imdb_most_popular_movies'),
imdbMostPopularTvShows('imdb_most_popular_tv_shows'),
imdbLowestRatedMovies('imdb_lowest_rated_movies'),
imdbTopEnglishMovies('imdb_top_english_movies'),
tmdbPopularMovies('tmdb_popular_movies'),
tmdbTopRatedMovies('tmdb_top_rated_movies'),
tmdbNowPlayingMovies('tmdb_now_playing_movies'),
tmdbUpcomingMovies('tmdb_upcoming_movies'),
tmdbPopularTv('tmdb_popular_tv'),
tmdbTopRatedTv('tmdb_top_rated_tv'),
tmdbAiringTodayTv('tmdb_airing_today_tv'),
tmdbOnTheAirTv('tmdb_on_the_air_tv'),
tmdbTrendingMovieDaily('tmdb_trending_movie_daily'),
tmdbTrendingMovieWeekly('tmdb_trending_movie_weekly'),
tmdbTrendingTvDaily('tmdb_trending_tv_daily'),
tmdbTrendingTvWeekly('tmdb_trending_tv_weekly'),
tmdbTrendingAllWeekly('tmdb_trending_all_weekly'),
radarrCalendar('radarr_calendar'),
sonarrCalendar('sonarr_calendar'),
```

**`serializedName` values are load-bearing** — they are persisted in
`home_sections_config` and sent to the server plugin. Copy them character for character.

Also add `seerrWatchlist('seerr_watchlist')` to `HomeSectionType` and `yourWatchlist` to
`SeerrRowType`, plus the two mapping arms in the `HomeSectionType get homeSectionType` /
`HomeSectionTypeSeerrRow` extensions (see upstream `preference_constants.dart` ~lines
579–608).

`HomeSectionType.none` must stay **last**. `fromSerialized` falls back to it.

Then add `custom('custom')` to `HomeSectionPluginSource` in
`lib/preference/home_section_config.dart` (Voltix currently has `hss`, `collections`,
`genres`, `playlists` only).

### Step 2 — Preferences (`lib/preference/user_preferences.dart`)

Copy verbatim from upstream `user_preferences.dart` lines **1998–2151**: the 6 `imdb*Enabled`,
13 `tmdb*Enabled`, `enableRadarrCalendar`, `enableSonarrCalendar`, the 4 `radarrCalendarShow*`,
the 2 `sonarrCalendarShow*`, `lastRadarrCalendarFetchTime`, `lastSonarrCalendarFetchTime`,
`mergeRadarrSonarrCalendars`, `lastExternalRowsRefreshTime`. All default `false` except the
`*Show*` flags (`true`) and the timestamps (`0`).

`tmdbApiKey` and `mdblistApiKey` are also referenced by the custom-row wizard — check
whether Voltix already has them and add if not.

Add the 6 IMDb + 13 TMDB + calendar keys to `_scopedPreferenceKeys` (upstream lines 262–267
and 468–480 show which are scoped). **Note:** these are the *string keys*, not the Dart
identifiers. There is an existing bug in this set — `_scopedPreferenceKeys` contains
`'seerrEnabled'` but the real key is `'seerr_enabled'`. Do not copy that mistake into the
new entries; use the exact `key:` values from the `Preference(...)` declarations.

Verify after: total preference count increased by the expected amount and **no duplicate
keys** (a duplicate key silently shadows a setting).

### Step 3 — `CustomExternalListsService`

Copy `lib/data/services/custom_external_lists_service.dart` from upstream essentially
verbatim. It imports `dio`, `path_provider`, `server_core`, `get_it`, plus
`../../preference/home_section_config.dart` and `../../util/platform_detection.dart` — all
of which Voltix has. Confirm `buildServerAuthorizationHeader` exists in Voltix's
`server_core`.

Register it in DI (`lib/di/modules/app_module.dart`) as a lazy singleton, alongside the
other data services.

### Step 4 — `row_data_source.dart`

Add the `case HomeSectionPluginSource.custom:` branch to `loadDynamicSection` — upstream
`row_data_source.dart` lines **1803–1862**. It:

- builds a `HomeSectionConfig.pluginDynamic(...)`
- calls `loadCustomRowFromCache` first, falls back to `fetchCustomRow` when the cache is empty,
  or goes straight to `fetchCustomRow(forceRefresh: true)` when refreshing
- maps `ImdbExternalListItem` → `AggregatedItem` with `serverId: 'seerr'` and a synthetic
  `rawData` map carrying `SeerrMediaType`, `PosterPath`, `BackdropPath`, `ProviderIds`
- returns `HomeRowType.pluginDynamic`

**Voltix caution:** Voltix's `AggregatedItem` and multi-server watch-registry code assume a
real `serverId`. The `'seerr'` sentinel is upstream's convention for externally-sourced
items. Check that Voltix's card-tap / watch-state paths tolerate it — in particular the
shared-server (Extra/4K) isolation logic. If an external card's tap handler tries to resolve
`'seerr'` as a real server it will throw. Test tapping an external row card explicitly.

### Step 5 — `home_view_model.dart`

Five separate edits. Upstream line references given:

1. **Type predicates** — `_isImdbSectionType`, `_isTmdbSectionType` (upstream 194–207, 259–265).
2. **Enabled checks** — `_isImdbSectionEnabled`, `_isTmdbSectionEnabled`,
   `_isAnyImdbSectionEnabled`, `_isAnyTmdbSectionEnabled` (upstream 210–256, 268–293).
3. **Visibility filter** — the `.where(...)` chain at upstream 424–427: an IMDb/TMDB section
   only shows when both "any enabled" and "this one enabled"; the calendars gate on
   `enableRadarrCalendar` / `enableSonarrCalendar`.
4. **Row→section matcher** and **`_rowIdsForSection`** — upstream 734–774 and 1029–1070.
   Row ids are the `serializedName` strings for the matcher and the **camelCase Dart
   identifiers** for `_rowIdsForSection`. They differ. Copy both exactly.
5. **Loader dispatch + skeleton placeholders** — upstream 1367–1432 and 1780–1926.
   You will need `_loadImdbRow`, `_loadTmdbChartRow`, `_loadRadarrCalendarRow`,
   `_loadSonarrCalendarRow` — port these helper methods too.

Also add the offline/no-network gate at upstream lines 162–174: external rows are skipped
when the device is offline, same as Seerr rows.

### Step 6 — Settings UI (`panel/external_lists_screen.dart`)

Copy upstream's file as a new part file. Add `part 'panel/external_lists_screen.dart';` to
`settings_side_panel.dart` and the two imports it needs at the top of the parent file:

```dart
import '../../../data/services/custom_external_lists_service.dart';
import '../../../data/repositories/seerr_repository.dart';
```

Then reconcile against Voltix:

- **`adaptiveListSection(children: [...])` → replace with Voltix's plain layout.** The
  simplest faithful substitution is to inline the children into the surrounding `ListView`
  (upstream's function returns a section wrapper; Voltix has no equivalent). Do this
  consistently across the whole file.
- **`showFocusRestoringDialog`** — if Voltix lacks it, substitute `showDialog` and note the
  TV focus-restoration regression in your report. Do not silently drop the `PopScope`
  wrapper; the refresh dialog must stay non-dismissible.
- **`SwitchPreferenceTile(onChangedValue: ...)`** — Voltix's `SwitchPreferenceTile` does
  support `onChangedValue` and `focusNode`. Verify the signature matches upstream's async
  usage (`onChangedValue: (isEnabled) async {...}`) before mass-copying.
- **`l10n.imdbTop250Movies` and friends** — these localisation keys almost certainly do not
  exist in Voltix's ARB files. Either add them to `lib/l10n/app_en.arb` (and regenerate) or
  replace with literal strings. **Pick one approach and apply it uniformly.** Upstream
  itself uses literal strings for the TMDB row titles, so mixed usage is normal.
- The `SeerrRepository.getRadarrSettings()` / `getSonarrSettings()` calls used to detect
  whether Radarr/Sonarr are installed **do exist** in Voltix
  (`lib/data/repositories/seerr_repository.dart:561,568`). Good.

### Step 7 — Entry point

In `panel/home_screen_category_screen.dart`, add the tile that opens the screen — upstream
`home_screen_category_screen.dart` lines 168–175:

```dart
if (GetIt.instance<PluginSyncService>().seerrAvailable)
  _TvSettingsListTile(
    leading: const Icon(Icons.link),
    title: const Text('External Home Rows'),
    subtitle: const Text('Set-up external sources for Home Rows (e.g., Seerr, IMDb, Letterboxd, and more!)'),
    onTap: () => context.pushSettingsScreen(const _ExternalListsScreen()),
  ),
```

While you are in this file, upstream also exposes the **per-row image type screen** here
(lines 159–167). Voltix has `home_rows_image_type_screen.dart` in its tree but **nothing
references it** — the screen is unreachable dead code. Wire it up with upstream's tile,
gated on `rowsStyle == HomeRowsStyle.v1`. This is a two-line fix for a real defect.

## 2.4 Definition of done for WO-2

- `flutter analyze` clean.
- Settings → Personalization → Home Screen → **External Home Rows** opens and lists the five
  sub-screens (IMDb, TMDB, Upcoming Calendars, Seerr, Custom).
- Enabling an IMDb row shows the fetch dialog, succeeds against the server plugin, and the
  row appears on Home after a reload. Turning it off removes the row.
- The custom-row wizard creates a working row from at least one source (Letterboxd or
  MDBList is easiest to verify).
- Tapping a card in an external row does not crash and resolves to a sensible detail view.
- Per-row image type is reachable from Home Screen settings when rows style is Classic.
- Radarr/Sonarr sub-screens hide themselves when neither service is configured.

## 2.5 Known risk register — report on each

1. **Server plugin `CustomRows` controller may not exist** on Voltix's servers (see §2.2).
   Highest-probability blocker.
2. **`serverId: 'seerr'` sentinel** may break Voltix's shared-server (Extra/4K) watch
   isolation or its multi-server repository. Test card taps.
3. **Missing l10n keys** — decide literal-vs-ARB up front.
4. **`adaptiveListSection` absence** means the ported screens will look flatter than
   upstream's grouped cards on iOS/macOS. Cosmetic, expected, worth stating.
5. **`_scopedPreferenceKeys` `'seerrEnabled'` typo** already exists in Voltix. Do not fix it
   as part of this work order (it needs a migration), but do not propagate the pattern.
6. **Preference key collisions** — run a duplicate-key check after Step 2.

---

## Appendix — quick orientation commands

```bash
# Voltix working tree
cd "C:\Voltix Newest"

# Upstream reference (read only)
cd "C:\Users\ShawneBedford\OneDrive - TLC - Think Logic Consulting (1)\Desktop\Moonfin-Core-2.4.0\Moonfin-Core-2.4.0"

# Verification (the only one available)
flutter analyze

# Part-file sanity check — must return nothing
grep -rn "^import" lib/ui/screens/settings/panel/

# Duplicate preference key check
grep -o "key: '[^']*'" lib/preference/user_preferences.dart | sort | uniq -d
```
