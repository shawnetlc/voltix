# Voltix ← Moonfin Core 2.4.0 — port progress

State file so nothing is lost between sessions. Update as work lands.

## Landed and structurally verified

| Tranche | What | Files | Verified |
|---|---|---|---|
| Taste-quiz removal | Custom quiz/taste-profile/recommendation system fully removed | 6 deleted, 21 edited | `flutter analyze` clean |
| Moonfin Recommends | Local content-based engine + Since You Watched rows (1–5) | `row_data_source.dart`, `home_view_model.dart`, prefs, `home_row_toggles_screen.dart` | `flutter analyze` clean |
| Prefs pass 1 | 59 preference definitions + 12 enums | `user_preferences.dart`, `preference_constants.dart` | 319 keys, 0 duplicates |
| Tranche 1 | Interface Style idiom + 12 button-layout preference definitions | `util/idiom/app_ui_idiom.dart` (new), `preference/button_layout.dart` (new), `app.dart` | balance-checked |
| Tranche 2 | Button layout wired end to end | see below | balance-checked, **needs `flutter analyze`** |
| Tranche 3 | Settings panel refactor — 4,013-line monolith → 274-line shell + 22 part files | `settings/panel/*` | lossless, proven by reconstruction; **needs `flutter analyze`** |
| Tranche 4 | Button layout editors + per-row image type fix | see below | balance-checked; **needs `flutter analyze`** |
| Tranche 5 | Details Screen + Theme Music screens; Loop Theme Music wired | `panel/details_screen_settings_screen.dart`, `panel/theme_music_screen.dart`, `theme_music_service.dart` | balance-checked, no duplicate tiles; **needs `flutter analyze`** |
| Tranche 6 | Rewatch row, end to end | `row_data_source.dart`, `home_view_model.dart`, `preference_constants.dart`, `home_section_config.dart`, `home_row_toggles_screen.dart` | 5 wiring points verified; **needs `flutter analyze`** |

### Tranche 2 detail (most recent)

New files:
- `lib/ui/screens/detail/detail_buttons.dart` — `enum DetailButton` (17 members), `detailButtonLayout`
- `lib/ui/screens/playback/osd_buttons.dart` — `enum OsdButton` (16 members), `visibleOsdButtonIds()`, `osdButtonLayout`

Edited:
- `lib/ui/screens/detail/item_detail_screen.dart` — action row converted from flat `List<Widget>` to
  `Map<DetailButton, Widget>` + `detailButtonLayout.ordered(...)`. Play extracted as `playActionButton`
  and still leads the row. Backup: `item_detail_screen.dart.bak-buttonlayout`
- `lib/ui/screens/playback/video_player_screen.dart` — OSD secondary row converted the same way;
  added `_wireTvSecondaryEnds` / `_withTvFocusNode` so the TV d-pad end nodes follow the arrangement
  instead of being hardcoded to the speed and info buttons. Backup: `video_player_screen.dart.bak-buttonlayout`

Deliberate divergences from upstream, so a future merge does not read them as drift:
- `DetailButton` omits upstream's five `seerr*` members (Voltix's details screen renders no Seerr buttons)
- Upstream's single `admin` member is split into Voltix's `editMetadata` + `deleteItem`
- `OsdButton.orientation` / `.fullscreen` reuse existing tooltip l10n keys; upstream's
  `orientationLock` and `fullscreen` keys do not exist in Voltix's ARB

Still missing for this tranche: the two settings editor screens
(`panel/detail_buttons_screen.dart`, `panel/osd_buttons_screen.dart`) and the
`button_layout_list.dart` reorder widget. They are `part` files and need the panel refactor first,
so the preferences are honoured but not yet user-editable.

### Tranche 3 detail — panel refactor (WO-1) COMPLETE

`settings_side_panel.dart` went from **4,013 lines / 57 classes** to a **275-line shell** plus
**22 part files** under `lib/ui/screens/settings/panel/`. Backup: `settings_side_panel.dart.bak-panelsplit`.

Verified lossless, not just plausible:
- every part file's brackets balance to zero
- the library's total `{}` `()` `[]` counts are **identical** to the pre-split file (326/1711/55)
- all 57 classes still present
- no part file contains an `import`; every one opens with `part of '../settings_side_panel.dart';`
- reconstructing the original by concatenating shell + part bodies in order reproduces it
  line for line (sole difference: one blank line in the whitespace between the imports and the
  first declaration)

Three part files have no upstream counterpart and are Voltix-only — keep them:
`plugin_category_screen.dart`, `offline_downloads_screen.dart`, and `_CloudSettingsSyncTile`
inside `settings_panel_tiles.dart`.

Not created (they need content that does not exist yet, and belong to later tranches):
`settings_search_field.dart`, `settings_search_index.dart`, `details_screen_settings_screen.dart`,
`theme_music_screen.dart`, `playback_time_layout_screen.dart`, `detail_buttons_screen.dart`,
`osd_buttons_screen.dart`, `external_lists_screen.dart`.

### Tranche 4 detail — button layout editors, and one defect fixed

Button layout is now user-editable, completing Tranche 2. 24 part files total.

New:
- `lib/ui/widgets/settings/button_layout_list.dart` — `ButtonLayoutList` + `ButtonLayoutEntry`.
  Reorder by arrows on pointer devices, left/right on a remote; hidden buttons sink below the
  shown ones; a `canHide: false` button shows a padlock instead of a switch.
- `panel/detail_buttons_screen.dart`, `panel/osd_buttons_screen.dart`

Supporting additions:
- `util/extensions.dart` += `ListExtensions.sortedEnabledAboveDisabled` (ported from upstream)
- `ui/widgets/settings/preference_tiles.dart` += `settingsTileInvertsOnFocus`, hardcoded `true`.
  Voltix's focused tile fills solid light so its content must flip. When Interface Style lands
  this should become `!AppUiIdiomResolver.isApple && !AppUiIdiomResolver.appleTvStyle`.

Entry points: **Personalization → Detail Buttons**, **Playback → Player Buttons**.

Also fixed, from §4 of the gap report: **`home_rows_image_type_screen.dart` was unreachable** —
it existed in the tree with nothing in `lib/` referencing it. Now wired into
Home Screen settings as *Per-Row Image Type*, gated on Classic rows the way upstream gates it.

Copy for all of the above is **inline English, not localised** — upstream's `detailButtons`,
`osdButtons`, `buttonOrderHint`, `moveUp`, `moveDown` and the two section-description keys do not
exist in Voltix's ARB, and the generated localisations cannot be regenerated in the porting
environment. Worth converting to ARB keys in a single pass later.

### Tranche 5 detail — Details Screen and Theme Music

26 part files now. Both screens are **relocations**, not additions — the controls already existed
in General Style and Home Screen, which is where upstream moved them *from*. Verified afterwards
that no preference has a tile on two screens.

- `panel/details_screen_settings_screen.dart` — background blur, recommendation system,
  parental-rating cap, and the Detail Buttons entry. Reached from Personalization → Details Screen.
- `panel/theme_music_screen.dart` — enabled, volume, on-home-rows, **and Loop Theme Music**.
  Reached from Personalization → Theme Music.

**Loop Theme Music is genuinely wired**, not just stored: `theme_music_service.dart` called
`setLoop()` unconditionally, so the theme always looped. It is now gated on `themeMusicLoop`,
which defaults to `true` — existing behaviour is unchanged until a user turns it off.

**Three upstream controls deliberately left out**, because their consumers do not exist in Voltix
and a switch that does nothing is worse than no switch:

| Control | Blocked on |
|---|---|
| `detailScreenStyle` (Classic vs Modern) | upstream's `ui/screens/detail/modern/` — ~200 KB, absent from Voltix entirely |
| `detailExpandedTabs` | same |
| `detailShowTechnicalDetails` | the `technicalDetailsFor` helper, absent from Voltix |

The preferences are already defined, so each becomes a few lines here once its consumer lands.

### Tranche 6 detail — Rewatch row

A complete Tier 1 feature, working end to end.

- `HomeSectionType.rewatch` added immediately before `none` (which `fromSerialized` falls back to)
- default `HomeSectionConfig` at order 45, disabled
- `loadRewatchRow` ported verbatim (218 lines). Every helper it needs already existed here with an
  identical signature: `_searchVisibleLibraryItems`, `_getItemsWithFallback`, `_byLastPlayed`,
  `_lastPlayedOf`, `_parseItems`
- `home_view_model.dart` wired at all five points: visibility gate on `displayRewatchRow`,
  exclusion from `latestMedia` (the rewatch row shares `HomeRowType.latestMedia`, so without this
  the latest-media section would swallow it), row-to-section matcher, loader, skeleton
- settings UI under **Home Row Toggles → REWATCH**: display toggle, sort-by, and three
  content-type switches

Shows only things actually finished — movies played, series with zero unplayed episodes,
collections where every child is watched.

## Next up

1. **External Home Rows** — IMDb/TMDB charts, Radarr/Sonarr calendars, custom row wizard. Same doc, WO-2.
   **Blocked on a server check:** confirm `GET /Moonfin/CustomRows/Items` returns 401 (route exists) and not 404.
3. **Modern detail screen** (`ui/screens/detail/modern/`, ~200 KB) — a large subsystem missing
    entirely, and the blocker for `detailScreenStyle` / `detailExpandedTabs`. This was undercounted
    in earlier estimates.
4. **Playback time layout** — bigger than first scoped: the 6 preferences exist, but both support
   files (`util/playback_time_label.dart`, `ui/widgets/playback/playback_time_row.dart`) are absent
   from Voltix and the player's seek-bar area needs rewiring. Medium, not small.
5. Wire the remaining definitions-only preferences into UI and consumers.
5. Interface Style: nothing reads `AppUiIdiomResolver` yet — needs the adaptive widget layer
   (`lib/ui/widgets/adaptive/` does not exist in Voltix).

## Open items not yet actioned

- **Plaintext passwords in backend server logs** — rotate the exposed credentials and redact
  `password` / `Pw` / `token` in the `[HTTP] Body:` logger.
- `_scopedPreferenceKeys` contains `'seerrEnabled'` but the real key is `'seerr_enabled'`, so that
  setting is not actually scoped per server. Needs a migration, not a rename.
- `seerrBlockNsfw` vs `jellyseerrBlockNsfw` duplication — needs a deliberate migration.
- Parallel audio-passthrough and subtitle-mode models (old Voltix + newly ported upstream) coexist.
- Glass Quality needs `voltix_design` additions that do not exist; native emulator needs platform code.

| **Tranche 7** | **Settings search** | `panel/settings_search_field.dart`, `panel/settings_search_index.dart`, shell, `custom_tv_text_field_fork` | 39 sections + 108 leaves, all ctors resolved; **needs `flutter analyze`** |

### Tranche 7 detail — settings search

The gap report called this "the first thing anyone notices". 28 part files now.

- `panel/settings_search_field.dart` — pill-shaped field; plain `TextField` off TV, `CustomTVTextField`
  on TV where it is a single d-pad stop whose keyboard only opens on select. All 18 constructor
  params verified against Voltix's fork.
- `panel/settings_search_index.dart` — **39 sections, 108 setting leaves**, with breadcrumb subtitles
  and a token-AND ranker (title-prefix > title-contains > keyword-only).

The index was **not hand-transcribed**. Every leaf title was extracted by script from the panel
screens' own `title:` expressions, so each one is an expression that already compiles in this
library. Adding a setting means re-running the extractor, not editing leaves by hand. The section
list (breadcrumbs, icons, constructors) is hand-written; all 39 constructors were taken from
`pushSettingsScreen(const X())` calls already present in compiling code, and all 15 public ones
were verified as reachable through the shell's imports.

Supporting change: Voltix's vendored `custom_tv_text_field_fork` is an older copy than upstream's
and lacked `isKeyboardVisibleNotifier`. Added it (declaration, publish on visibility change, clear
on dispose) — additive, nothing else in Voltix uses it. It is what stops the search field stealing
key events from the on-screen keyboard grid on TV.

Search hint copy is the literal `'Search settings'` — `settingsSearchHint` is not in Voltix's ARB.

## flutter analyze — first run across Tranches 1-6

**3 issues total**, all now fixed:

| Severity | Where | Cause | Fix |
|---|---|---|---|
| error | `button_layout_list.dart:207` | `KeyDownEvent` undefined — the `flutter/services.dart` import was dropped while adapting the file from upstream | import restored |
| warning | `button_layout_list.dart:207` | dead code, purely a knock-on of the above | cleared by the same fix |
| info | `video_player_screen.dart:4841` | `use_null_aware_elements` — a defensive `if (x != null) k: x` written while unable to compile | switched to `k: ?x`, matching upstream |

Worth noting what produced **zero** errors: the 4,013-line panel split into 22 part files, the
details-screen and OSD button-row conversions, the Details Screen and Theme Music relocations, and
the Rewatch row wiring. The one real error was a dropped import in a hand-adapted file — exactly
the class of mistake the structural checks cannot catch, and the reason the analyze run matters.

The run took 221s and may have started before the Rewatch tranche landed. **Re-run to confirm**
these two fixes and cover Rewatch.

| **Tranche 8** | **Adaptive widget layer (partial) + Interface Style now visible** | `ui/widgets/adaptive/*`, shell + 8 panel screens | balance-checked; **needs `flutter analyze`** |

### Tranche 8 detail — adaptive widget layer

`lib/ui/widgets/adaptive/` did not exist in Voltix. It now holds three of upstream's seven files.
This is the tranche that finally gives **Interface Style** a visible effect, and it is the
prerequisite that makes upstream's `external_lists_screen.dart` (100 KB, which uses
`adaptiveListSection` throughout) a near-straight copy rather than a rewrite.

Ported:

| File | Fidelity |
|---|---|
| `adaptive_dialog.dart` | verbatim |
| `adaptive_slider.dart` | verbatim |
| `adaptive_list_section.dart` | **degraded** — see below |

Deliberately skipped, with reasons:

| File | Blocked on |
|---|---|
| `adaptive_glass.dart` | `glassPane` / `GlassSettings` / `GlassTier` / `GlassCapability` — the whole glass subsystem is absent from `voltix_design` |
| `sf_symbol.dart` | a native `MethodChannel('moonfin/sf_symbols')` with iOS/macOS/tvOS implementations. It fails soft to Material icons, so porting it buys nothing until the native side exists |
| `adaptive_icons.dart` | only exists to serve `sf_symbol.dart` |
| `adaptive_segmented.dart` | needs `AppRadius`, absent from `voltix_design`; and nothing in Voltix consumes it yet |

**The degradation, stated plainly:** upstream draws the grouped card with a real blurred glass
pane. Voltix's copy uses a flat translucent rounded surface of the same geometry. To close it,
port the glass subsystem into `voltix_design` and swap `_sectionSurface` for `adaptiveGlass`.

**Adoption:** the shell's category list plus 8 panel screens now wrap their tiles in
`adaptiveListSection`. Only screens with a flat run of tiles and no interleaved `_SectionHeader`
were converted — the 8 screens that interleave headers need per-run grouping and are left for a
deliberate pass rather than a regex sweep. `plugin_screen.dart` did not match the pattern and was
skipped.

**Risk profile of the adoption: near zero off Apple.** The non-Apple branch returns exactly the
plain `Column` these screens used before, so Android, Android TV, Windows and Linux render
identically. Only the Apple idiom takes the new path.

| **Tranche 9** | **Glass subsystem ported into `voltix_design` — like-for-like** | `packages/design/*`, `glass_capability.dart`, `adaptive_glass.dart`, `app.dart` | balance-checked; **needs `flutter pub get` then `flutter analyze`** |

### Tranche 9 detail — the glass subsystem

Closes the degradation flagged in Tranche 8. `adaptive_list_section.dart` is now
**byte-identical to upstream** apart from the package name.

Copied verbatim into `packages/design/lib/`:

| File | Lines | Provides |
|---|---|---|
| `src/theme/glass_settings.dart` | 93 | `GlassTier`, `GlassSettings` (sigma caps, tier, package renderer) |
| `src/theme/app_radius.dart` | 12 | `AppRadius` |
| `src/theme/color_alpha.dart` | 9 | `ColorAlphaScaling.scaleAlpha` |
| `src/widgets/glass_recipe.dart` | 219 | `GlassRecipe`, **`glassPane`**, `GlassHairlinePainter` |
| `src/widgets/pixel_border_painter.dart` | 88 | `PixelBorderPainter` |
| `src/widgets/glass_surface.dart` | 63 | replaces Voltix's older 106-line copy |
| `src/widgets/glass_backdrop.dart` | 185 | replaces Voltix's older 122-line copy |

App side: `lib/util/idiom/glass_capability.dart` and `lib/ui/widgets/adaptive/adaptive_glass.dart`,
both verbatim; `app.dart` now calls `GlassCapability.apply()` at startup and re-applies on both
Glass Quality and Interface Style changes (the idiom feeds `glassLookActive`, so a style change can
turn glass on or off without the quality preference moving).

**Replacing the two existing widgets was safe**: `GlassSurface`'s constructor is identical in both
trees (`cornerRadius`, `reinforced`, `fallbackColor`, `padding`, `child`), and Voltix's 8 consumers
(`app.dart`, `left_sidebar`, `media_bar`, `mini_audio_player`, `navigation_layout`,
`settings_panel`, `top_toolbar`, `track_selector_dialog`) all pass that same set.

Two reconciliations, both additive:
- `AppColorScheme.isPixel` did not exist. Upstream reads it off `ThemeSpec.isPixel`, a flag tied to
  the 8-bit Hero theme Voltix has not ported, so it is a constant `false` here. `AppRadius`,
  `GlassSurface` and `PixelBorderPainter` are ported whole, so adding that theme later is a
  one-line change.
- `PlatformDetection.osMajor` (the cached variant) was missing; added beside the existing
  `iosMajorVersion`.

**ACTION REQUIRED: `flutter pub get`.** This adds a real external dependency,
`liquid_glass_widgets: 0.22.1`, to `packages/design/pubspec.yaml` — pinned exactly as upstream pins
it. It cannot be fetched from the porting environment. `flutter analyze` will fail on every glass
file until that resolves, and that failure is expected, not a port defect.

| **Tranche 10** | **`adaptive_segmented` + External Home Rows foundation** | prefs, enums, service, DI, `row_data_source` | balance-checked; **needs `flutter pub get` then `flutter analyze`** |

### Tranche 10 detail

**`adaptive_segmented.dart`** — ported, now that `AppRadius` exists. Identical to upstream apart
from the package name. 4 of upstream's 7 adaptive files are now in; only the SF Symbols pair
(needs a native MethodChannel) remains.

**Abandoned: `adaptiveListSection` on the header-interleaved screens.** A dry run showed this is
not safely mechanizable and I stopped rather than force it. `_SectionHeader` sits at different
nesting depths per screen — a top-level element split found 1 header in
`audio_preferences_screen.dart` where grep finds 5, because the rest are inside conditional
spreads — and spacer `SizedBox`es are interleaved between tiles. Wrapping mechanically produced
runs like `[1, 1, 1, 3, 1]` for `about_category_screen.dart`, which would fragment the layout.
These 6 screens need doing by hand, one at a time. The payoff is Apple-idiom-only grouping, so it
is low priority against what is left.

**External Home Rows — foundation only.** The half that is mechanical is done:

| Piece | State |
|---|---|
| 21 `HomeSectionType` members (6 IMDb, 13 TMDB, Radarr + Sonarr calendars) | done, `none` still last |
| 18 preferences | done, 9 scoped per server. **The 13 `tmdb_*` prefs already existed in this fork** — I had said 19 were missing; it was 18, and none of them TMDB |
| `HomeSectionPluginSource.custom` | done |
| `CustomExternalListsService` (308 lines) | copied verbatim; `dio`, `path_provider`, `buildServerAuthorizationHeader`, and `MediaServerClient.baseUrl/accessToken/deviceInfo` all confirmed present |
| DI registration | done |
| `loadDynamicSection` `custom` branch + `forceRefresh` param | done |
| The three exhaustive switches the 21 members break | done, pre-emptively this time |

**Tranche 11 added the view-model wiring for the 19 chart rows.** Per member: a type predicate, an
enabled check, a visibility gate, a matcher arm, a loader arm and a skeleton arm — verified as
5+ references each.

New in `home_view_model.dart`:
`_isImdbSectionType`, `_isImdbSectionEnabled`, `_isAnyImdbSectionEnabled`, the three TMDB
equivalents, `_tmdbChartTypeForSection`, `_loadImdbRow`, `_loadTmdbChartRow`.

**One deliberate divergence from upstream.** Upstream's `_loadImdbRow` and `_loadTmdbChartRow` are
two ~60-line methods that differ only in the `source` and `type` they send. Here they are thin
wrappers over a shared `_loadExternalChartRow`, with `_mapExternalListItems` extracted. Same
behaviour, same request payloads, a third of the code. Flagged because it is the one place in this
feature that is not a literal copy.

**Still to do for this feature:**
- The **Radarr/Sonarr calendar rows** (2 of the 21 members). Deliberately deferred: they need
  ~10 further helpers (`_loadMergedCalendarRow`, `_fetch*FromApi`, `_save*ToCache`,
  `_load*FromCache`, `_filterAndFormat*Items` for both services) plus Seerr calendar endpoints.
  Their enum members exist with no loader, which is safe — the loader switch has a `default`, the
  preferences default false, and no default `HomeSectionConfig` entry was added.
**Tranche 12 added the settings UI**, so the 19 chart rows are now reachable rather than merely
wired. 29 part files.

`panel/external_lists_screen.dart` (932 lines) holds:
- `_ExternalListsScreen` — the hub, reached from **Personalization -> Home Screen -> External Home
  Rows**, gated on `PluginSyncService.pluginAvailable`. Includes upstream's *Refresh All Enabled
  Lists* action.
- `_ImdbListsScreen` — 6 switches
- `_TmdbListsScreen` — 13 switches, gated on `PluginSyncService.tmdbAvailable`
- `_ExternalChartScreenMixin` — the shared pre-fetch-on-enable behaviour

Turning a chart on pre-fetches it through the plugin behind a non-dismissible progress dialog and
**reverts the switch if the fetch fails**, so a row is never enabled against an empty cache. The
matching `HomeSectionConfig` entry is created or updated so the choice survives a settings sync.

**Divergence from upstream, again in the direction of less duplication:** upstream repeats the
fetch/sync/dialog logic inside both `_ImdbListsScreenState` and `_TmdbListsScreenState`. Here it
lives once in `_ExternalChartScreenMixin`, with the two screens supplying only `_chartSource` and
`_chartType`. Same behaviour and same request payloads.

Four shell imports were needed for this part file: `dart:convert`,
`custom_external_lists_service.dart`, `home_section_config.dart` (part files inherit the shell's
imports, so they belong there rather than in the part).

**Tranche 13 added the Custom Home Rows wizard.** `external_lists_screen.dart` is now 2,211 lines
with 12 classes.

`_CustomListsScreen`, `_AddEditCustomRowDialog` and `_SettingsTextField` were **extracted from
upstream as a 1,260-line slice and appended unchanged** — the same approach used for
`loadRewatchRow`, and preferable to transcribing that much UI by hand. The slice balance-checked
clean before insertion and every symbol it needs resolves through the shell's imports.

**This needed no new loader.** Custom rows are plugin-dynamic configs carrying
`HomeSectionPluginSource.custom`, and `HomeViewModel._loadConfig` already routes those through
`RowDataSource.loadDynamicSection`, whose `custom` branch landed in Tranche 10. So the wizard is
pure UI on top of a path that was already working.

What it gives you: build a row from **TMDB** (collection or list), **Letterboxd** (user diary,
watchlist, films) or **MDBList** (list by user ID or by URL), with sort-by / sort-order / show-user-
ratings options, edit and delete, and validation that fetches the row before saving and shows the
constructed source URL when it fails.

One fix to my own generated code: the IMDb/TMDB state classes came out as `__ImdbListsScreenState`
with a double underscore (the generator prefixed an already-underscored class name). Valid Dart but
sloppy; renamed.

**Still to do for External Home Rows:**
- Radarr/Sonarr calendar rows and their `_UpcomingCalendarsScreen` — needs ~10 helpers plus a merge
  mode where enabling both collapses them into one row
- Seerr discovery rows (`_SeerrListsScreen`) — Voltix maps `SeerrRowType` differently from upstream,
  and `seerrWatchlist` / `SeerrRowType.yourWatchlist` are still absent

**BLOCKER CLEARED (23 Aug 2026).** `GET https://main.lumistream.cc/Moonfin/CustomRows/Items` returns
**401 Unauthorized**, not 404 — the plugin's CustomRows controller exists and is reachable. Every
piece of this feature that depends on it is therefore viable.

## Tranches 14-16 — Seerr Watchlist, calendars, and the tail

**Seerr Watchlist row.** Needed an API layer, not just an enum member: `getWatchlist` /
`addToWatchlist` / `removeFromWatchlist` in `seerr_http_client.dart` (Voltix had none),
three `SeerrRepository` wrappers, `SeerrRowType.yourWatchlist('watchlist')`,
`HomeSectionType.seerrWatchlist`, the `_loadPage` dispatch, the title arm, a `SeerrRowConfig`
default, and five `home_view_model` sites. Seerr returns watchlist entries keyed by `tmdbId`
with media nested under `media` where every other discover endpoint uses `id`/`mediaInfo`;
upstream normalises that inside `getWatchlist`, and that normalisation was kept — without it
the row renders blank cards.

**Radarr/Sonarr calendars.** A 641-line upstream slice: both loaders, disk caching with a
one-day TTL, the API fetches, and the merge mode where enabling both collapses them into one
row. Plus `_CalendarItemWithDate`. Ported because you asked for like-for-like and the
alternative was stub switch arms.

**Playback time layout.** `util/playback_time_label.dart` and
`ui/widgets/playback/playback_time_row.dart` copied; `panel/playback_time_layout_screen.dart`
added; and — the part that matters — `video_player_screen.dart` now *honours* it. The fixed
elapsed/total pair under the seek bar is replaced by the six configurable slots, with an empty
row skipped entirely. Not another stored-but-inert setting.

**Last preference gaps closed.** `LibraryGroupBy`, `LibraryScrollDirection`, the two
per-library template preferences, and the six per-item/per-series track-memory accessors
(with `SeriesTrackPreference` copied from upstream). `LibrarySortBy` replaced with upstream's
12-member version including `usesDedicatedEndpoint` and `itemsApiValues`.

**De-duplications reverted, as requested.** Both places where I had collapsed upstream
duplication are now literal copies: the two chart loaders in `home_view_model.dart`, and
`_fetchAndCacheList` / `_syncSingleSectionState` inlined into each of `_ImdbListsScreenState`
and `_TmdbListsScreenState` (the `_ExternalChartScreenMixin` is gone).

### Parity as measured, not estimated

| | Then | Now |
|---|---|---|
| Missing preferences | 106 | **2** |
| Missing enum types | 20 | **1** |
| Missing `HomeSectionType` members | 25 | **0** |
| Missing `SeerrRowType` / `LibrarySortBy` members | 1 / 4 | **0 / 0** |
| Missing settings screens | 9 | **2** |
| Tier 1 features done | 0 of 9 | **8 of 9** |

### What genuinely cannot be finished here

| Item | Why |
|---|---|
| `detail/modern/` (~200 KB) — Modern detail screen | A subsystem of its own, and the blocker for `detailScreenStyle` / `detailExpandedTabs`. Not a copy job: it is a second detail-screen implementation |
| `sf_symbol.dart` + `adaptive_icons.dart` | Need a native `MethodChannel('moonfin/sf_symbols')` with iOS/macOS/tvOS implementations. Fails soft to Material icons, so porting buys nothing until the native side exists |
| `emulator_cores_screen.dart`, `downloaded_games_screen.dart`, `pref_use_native_emulator` | Need the native libretro backend |
| `PassthroughCodec` + audio model reconciliation | The gap report's warning stands: Voltix has a `truehd` member upstream lacks, and a naive port loses your Atmos handling. Needs a deliberate decision, not a copy |
| `seerrBlockNsfw` | Voltix renamed it `jellyseerrBlockNsfw`. Reconciling needs a migration |
| `adaptiveListSection` on 6 header-interleaved screens | Not mechanizable (see Tranche 10). By hand, and Apple-idiom cosmetics only |
| 23 default-value drifts | Decisions for you, not code |

## flutter analyze — second run (Tranches 1-7)

**16 issues: 5 errors, 11 infos. All fixed.** Run time dropped 221s -> 10s (warm cache).

| Severity | Where | Cause | Fix |
|---|---|---|---|
| error x3 | `home_view_model._duplicateKeysForBuiltin`, `home_sections_screen._labelForType`, `home_rows_image_type_screen._sectionLabel` | adding `HomeSectionType.rewatch` broke three **exhaustive** switches elsewhere | a `rewatch` arm in each |
| error | `settings_side_panel.dart:378` | search results pass `key:` to `_TvSettingsListTile`, whose ctor had no `super.key` (upstream's does; Voltix's copy had lost it) | `super.key` restored in `settings_panel_infra.dart` |
| info x11 | `settings_search_index.dart` | the generator emitted `snake_case` locals from hyphenated slugs | renamed to lowerCamelCase |
| info | `row_data_source.dart` | redundant `'$_fields'` interpolation, inherited from the upstream `loadRewatchRow` copy | `_fields` |

**Lesson worth keeping:** adding one enum member to `HomeSectionType` broke three switches in
unrelated files. Dart's exhaustiveness checking catches this, but *only at compile time* — no
structural check can. Any future enum addition (the 22 external-list members especially) should
expect the same and be followed by an analyze run.

**If the index generator is ever re-run, make it emit lowerCamelCase locals** rather than
replacing hyphens with underscores.

## Verification note

There is no Dart/Flutter SDK in the porting environment, so `flutter analyze` on your machine is the
only real compile check. Run it after each tranche.

## Tranche 13 — Seerr model layer now defines `Moonfin*`

Your instruction: *"the seerr must define Moonfin\* not Voltix\*"*. Done, and it was the right
call — the plugin on the server is Moonfin, so the fork's `Voltix*` spelling was describing the
app rather than the thing on the wire.

### What changed

| File | Change |
|---|---|
| `seerr_models.dart` | replaced with upstream's. Now defines `MoonfinProxyConfig`, `MoonfinQuickConnectResult`, `MoonfinStatusResponse`, `MoonfinLoginRequest`, `MoonfinLoginResponse`, `MoonfinValidateResponse`, `SeerrMainSettings`, `SeerrStatus`, `SeerrMediaSummary` |
| `seerr_models.g.dart` | replaced with upstream's, plus the one divergence below |
| `seerr_http_client.dart` | `getVoltixStatus`→`getMoonfinStatus`, `voltixLogin`→`moonfinLogin`, `voltixLogout`→`moonfinLogout`, `voltixValidate`→`moonfinValidate`, `_voltixUrl`→`_moonfinUrl` |
| `seerr_repository.dart` | class + method renames, `status.jellyseerrUserId`→`status.seerrUserId` |
| `seerr_config_screen.dart` | class renames only |

`MoonfinQuickConnectResult` and `SeerrMediaSummary` come across unused for now — they are what the
Quick Connect sign in and the request/issue cards need later, so they land with the rest of the file
rather than being trimmed and re-added.

### One deliberate divergence, and why

Upstream renamed the wire field `jellyseerrUserId` -> `seerrUserId` between 2.2 and 2.4. Which of
the two your **server plugin** sends depends on which plugin build is installed on it, and I could
not check that from here. A straight port would have parsed `seerrUserId` only, and on an older
plugin the sign in would have come back with a null user id — silently, because the field is
nullable. So the Dart field is upstream's name and reads both keys:

```dart
Object? _readSeerrUserId(Map<dynamic, dynamic> json, String key) =>
    json[key] ?? json['jellyseerrUserId'];
```

It is annotation-driven (`@JsonKey(readValue: _readSeerrUserId)`), so `build_runner` regenerates it
intact. If you confirm the server is on the 2.4 plugin, the fallback can be dropped.

### What was deliberately *not* renamed

- `Destinations.voltixLogin` and everything around it — that is the fork's own account login screen,
  nothing to do with Seerr.
- The persisted preference keys `voltix_mode`, `voltix_display_name`, `voltix_user_id`,
  `voltix_autologin_failed`, and the stored `auth_method` value `'voltix'`. Renaming a stored key
  logs every existing user out of Seerr for no gain. Upstream spells these `moonfin_*`; that is a
  migration, not a rename, and it is not worth doing.
- `isVoltixMode` / `loginWithVoltix` / `logoutVoltix` on the repository — fork-side API names above
  the wire layer, with call sites in fork-only screens.

### Verification

Per-symbol exact-count assertions before each substitution (an early run **failed correctly**: I
predicted 9 `VoltixStatusResponse` occurrences and there were 8, and predicted 2 `seerrUserId`
field declarations when upstream has 3 — the third is on the hand-parsed `MoonfinQuickConnectResult`
and must not be annotated). Post-pass greps confirm no old class name survives anywhere in `lib/`,
`packages/` or `test/`. Bracket balance holds on all 7 Seerr files. Structural only — needs
`flutter analyze`.

### Still open, and it needs a decision from you

`seerr_media_detail_view_model.dart` is **not** a superset either way. Voltix has 12 state members
upstream dropped; upstream adds 12 Voltix lacks, plus `SeerrQualityStatus` and `canReportIssue`.
Three files consume the old 12. See Tranche 14 below.

## Tranche 14 — Seerr detail slice (the unlock)

New files, both verbatim from upstream and self-contained:

- `lib/data/services/seerr/seerr_error.dart` — `SeerrRequestErrorKind` + `SeerrRequestException`
- `lib/data/services/seerr/seerr_download_progress.dart` — `SeerrDownloadSummary` (promoted out of `_parked_2_4/`, byte-identical to upstream)

Additions:

| File | Added |
|---|---|
| `seerr_http_client.dart` | `_throwIfRequestError` + 3 call sites (createRequest, deleteRequest, `_postRequestAction`), `getUserQuota`, `createIssue`, `getPublicSettings` |
| `seerr_repository.dart` | `getMovieDetailsWithWatchlist`, `getTvDetailsWithWatchlist`, `getUserQuota`, `createIssue`, `getPublicSettings` (session-cached) |
| `seerr_media_detail_view_model.dart` | **replaced** with upstream's 897-line version: `SeerrQualityStatus` (per-quality HD/4K tracks with season availability), quota, issue reporting, watchlist toggle, download polling, typed request errors, `bestSearchMatch`, IMDb-id resolution, 4K gating on `movie4kEnabled`/`series4kEnabled` |

Voltix keeps its CSRF handling on the mutations, which upstream 2.4 dropped — `_throwIfRequestError`
was slotted in around it rather than taking upstream's CSRF-free bodies.

### Fork shim, deliberate

Upstream folded 12 state members into `SeerrQualityStatus`. Voltix's 2,300-line detail screen reads
them off the state in ~30 places. Rather than rewrite a screen that is itself queued for
replacement, those 12 come back as thin delegates on `SeerrMediaDetailState`, each keeping its 2.2
meaning: the status flags follow the HD track (which is what `mediaInfo.status` was) and the request
lists span both qualities (which is what the unfiltered request list was). Marked with a banner
comment to remove once the screen moves to `hd`/`uhd`.

`load()` also changed shape — `load(int, String)` became `load(String itemId, String mediaType,
{String? title})`, which resolves an IMDb `tt...` id by search. The one call site was updated and
the old `int.tryParse` guard, which silently dropped IMDb ids, is gone.

### Verification

Every symbol the new view model references now resolves in Voltix: `SeerrDownloadSummary`,
`SeerrRequestException`, `SeerrRequestErrorKind`, `SeerrQuota`, `SeerrSeasonAvailability`,
`SeerrSeasonRequest`, `SeerrDownloadingItem`, and all 7 repository methods, plus
`canRequest4kTv` / `canRequest4kMovies` / `canCreateIssues` on `SeerrUser`. Bracket balance holds on
all 6 touched files. **Needs `flutter analyze`.**

The other two suspected consumers, `seerr_discover_view_model.dart` and `home_view_model.dart`, turned
out **not** to be affected — their `isBlacklisted` reads are on `SeerrDiscoverItem`, not on the
detail state. Sizing that from a bare symbol grep would have produced two unnecessary rewrites.

## Tranche 15 — the parked Seerr widgets come home

The `_parked_2_4/` inventory was 22 files. **19 are now in `lib/`**, one was already ported, one is
`focus_scroll.dart` (ported here from upstream), and one is blocked — see below.

### What it took to unblock them

| Gap | Fix |
|---|---|
| 15 missing l10n keys | ported into all 59 generated `app_localizations*.dart` files **and** all 68 `.arb` files, taking each locale's real translation from upstream rather than falling everything back to English |
| `AppColorScheme.statusError` | added to `ThemeSemanticTokens` in `theme_spec.dart` + the accessor on `AppColorScheme` |
| `OledTuning` | new `packages/design/lib/src/theme/oled_tuning.dart`, exported from the barrel |
| `lib/util/focus/focus_scroll.dart` | ported from upstream |

Files now in `lib/`: `ui/theme/vibrance.dart`, `ui/widgets/focus/glass_focus_halo.dart`,
`ui/widgets/image_source.dart`, `ui/widgets/offline_aware_image.dart`,
`ui/widgets/seerr_download_progress_bar.dart`, `util/overview_text.dart`, and 13 under
`ui/widgets/seerr/`: advanced request options, browse chip, image urls, item chips, item status,
quota row, request action, request dialog, stats card, status dot, status pill, tags dialog, tv
controls.

### The l10n port, and why it was not just an `.arb` edit

There is no Flutter SDK here, so `gen-l10n` cannot run — the generated Dart had to be written by
hand. Two things made that non-trivial and are worth recording:

1. **Placeholder keys become methods, not getters.** Five of the fifteen take arguments
   (`movieQuotaRemaining(int, int)`, `seasonQuotaRemaining(int, int)`,
   `partOfCollectionName(String)`, `requestSeriesOrMovie4k(String)`,
   `seerrDownloadingPercent(int)`), so each locale's member is a multi-line body, not a one-liner.
2. **`pt` and `zh` hold several classes each** (`Pt`/`PtBr`/`PtPt`, `Zh`/`ZhHant`), and a generated
   subclass only overrides the keys whose translation differs from its parent. My first pass asserted
   one occurrence per key per file and **failed on exactly those two files** rather than writing
   something wrong — the assertion earned its keep. They were redone per class, inserting only the
   members upstream actually overrides there (15 / 7 / 7 and 15 / 7).

`statusError` was added as an **optional** field with a default and a `containsKey`-guarded parse,
which is what upstream does. Every other field in `ThemeSemanticTokens` is `required`; making this
one required too would have broken every theme construction site and every custom theme JSON already
saved on a device.

### Still blocked: one file

`ui/widgets/seerr/seerr_collection_banner.dart` needs `Destinations.seerrCollection`, which needs the
whole collection slice: `seerr_collection_view_model.dart` (210 lines),
`seerr_collection_screen.dart` (614), `quick_return_wrapper.dart` (288), one more l10n key
(`scrollToTop`), a `Destinations` constant + helper, and a router entry. All the *files* it imports
exist in Voltix — but that is exactly the check that produced the 439-error run, so the screen's
argument lists get verified against Voltix's `LibraryRow` / `MediaCard` / `NavigationLayout` before
anything is written.

### Verification

Zero unresolved relative imports across the 19 new files. No app-specific undeclared type in any of
them. Bracket balance holds on all 83 touched Dart files. All 68 `.arb` files still parse as JSON.
Every base locale class declares all 15 new keys (subclasses inherit), verified per class.

**Run `flutter analyze` before the collection slice goes in** — this tranche touched 83 Dart files
plus 68 arb files, and stacking more on top of it would blur which change caused what.

## flutter analyze — run 6 (587 issues). Two causes, one of them mine.

### 585 errors: my l10n extractor had a third case it did not handle

Nine names — `advancedOptions`, `noServiceServersConfigured`, `server`, `qualityProfile`,
`rootFolder`, `showMore`, `appearances`, `crewSection`, `ageValue` — came back as
`duplicate_definition` in **every** locale file.

The cause: generated l10n members come in three shapes, and my extractor closed only two.

```dart
String get x => 'short';                 // ends in ';'  -- handled
String f(int a) { return '...'; }        // ends in '{'   -- handled, closed on '  }'
String get seerrSeriesContinuing =>      // ends in '=>'  -- NOT handled
    'Series Continuing · Future Seasons Can Be Requested';
```

For the third shape my scan ran on to the next `  }`, swallowing the **eight following members
plus `ageValue`** into the block I then copied. Every locale got those nine re-declared.

A second, smaller mistake compounded it: the first pass inserted after *every* occurrence of the
anchor member, so regional subclasses (`AppLocalizationsEnGb`, the four `Es*` variants,
`AppLocalizationsYue*`) each received a duplicate copy of all 15 keys as well.

**Repair.** There is no git here, so the revert had to be exact rather than approximate. The buggy
generator is deterministic, so I re-ran it to reproduce the precise text it had inserted, asserted
that text appeared in each file, removed it, and asserted that no trace of the 15 keys survived
anywhere. Then re-inserted with the extractor fixed and the insertion moved to the end of each class,
per class, so a subclass only receives what upstream actually overrides there.

Result: `AppLocalizations:15`, `AppLocalizationsEn:15` / `EnGb:0`, `Es:15` / four variants `:0`,
`Pt:15` / `PtBr:7` / `PtPt:7`, `Zh:15` / `ZhHant:7`.

**The check I should have run the first time** and now do: no member may be declared twice within one
class. Bracket balance and "the key exists" both passed on the broken files — neither could have
caught this. Verified clean across all 59 files.

### 2 errors: `ItemDetailViewModel.seerr` does not exist

`seerr_item_status.dart` reads `viewModel.seerr?.state`. Upstream's `ItemDetailViewModel` carries a
whole Seerr slice behind that getter — a lazily built `SeerrMediaDetailViewModel` per library item,
a TMDB-id resolve step, `PluginSyncService.seerrAvailable`, `_seerrRawData`, `_seerrSeasons`,
`seerrResolvedLibraryId`, `seerrOnlyTitle`. That is the "Seerr status on library items" feature and
it belongs with the modern detail screen, not bolted on here.

Nothing in `lib/` imports `seerr_item_status.dart` yet, so it is **parked again** at no cost. The
`ItemDetailViewModel` Seerr slice becomes its own tranche, ahead of the modern detail screen.

18 of the 19 files from Tranche 15 stay in `lib/`.

## assets/themes — why 10 of the bundled themes never appeared

You were right that something was wrong here. The wiring is all present and correct — the folder is
declared in `pubspec.yaml`, `main.dart` calls `seedBundledThemes()` then `loadAndRegister()` before
the active theme resolves, and `bundledThemeAssets` lists all 16 files with no typos. The failure was
one word.

### The bug

`ThemeSemanticTokens.fromJson` reads `json['mediaTypeBadgeShow']`. **Eleven of the sixteen bundled
theme files spell that key `mediaTypeBadgeSeries`.**

`_parseColor(null, ...)` throws `ThemeSpecParseException`. `seedBundledThemes` wraps each asset in
`catch (_) { }` so one bad file cannot stop the rest — so each of those eleven threw, was swallowed
without a trace, and never registered. One of the eleven is `voltix.theme.json`, whose id collides
with the built-in `voltix` and is skipped by design anyway, so the real damage was **10 themes
silently missing from Saved Themes**: amethyst_dream, arctic_aurora, crimson_noir, cyberpunk_neon,
dracula_prime, emerald_luxury, solar_flare, studio_oled, sunset_boulevard, tokyo_drift.

The five that worked did so for two different reasons: midnight, redflix, greenlu and bluesneyplus
use the `mediaTypeBadgeShow` spelling, and `voltix_classic` has no `semantic` block at all, which
`ThemeSpec.fromJson` already guards by falling back to defaults.

### The fix, three parts

1. **`mediaTypeBadgeSeries` is accepted as an alias.** The catalog these were snapshotted from is
   third-party, so the other spelling has to keep working rather than be corrected file by file.
2. **Every semantic accent now falls back to its default instead of throwing** (`_parseColorOr`).
   These are decorations — a theme missing one should lose that colour, not vanish. A present but
   *malformed* value still throws, because that is a broken theme rather than an absent key.
3. **The seed marker moved `.seeded_v2` -> `.seeded_v3`.** Without this the fix would change nothing
   for anyone who has already launched the app: they hold a v2 marker, `seedBundledThemes` returns
   early, and the ten themes stay missing forever.

Verified: all 16 files now satisfy every mandatory key — 29 in `colors`, 7 in `borders`, 12 in
`book`, 0 now in `semantic`.

### And the reason it went unnoticed

`catch (_) {}` in both `seedBundledThemes` and `loadAndRegister`. Both now `debugPrint` the failure.
A theme that cannot load is worth a line in the log; ten of them silently disappearing is not
something a structural check will ever surface.

**A caution about my own verification here.** My first validator reported `ThemeColorTokens` as
having *zero* mandatory keys and passed all 16 files on that basis. That was wrong:
`ThemeColorTokens.fromJson` reads its 29 colours through a local `Color c(String key)` helper, which
my regex did not match, so the most important section was never actually checked. Re-run with helper
extraction it reports 29 and still passes all 16 — but the first "ok" was worth nothing.

### Two other asset findings, both benign

- `assets/vault_posters/` (22 files) and `assets/splash.mp4` are **not** declared in `pubspec.yaml`,
  and nothing in the codebase references either. They are leftovers from the poster-export scripts.
  Leaving them undeclared is correct — declaring them would add 22 images to every build for nothing.
- `assets/packages/rar/web/rar_web.js` looked unbundled but is not: `packages/rar_fork` declares it,
  and Flutter bundles a dependency's assets under `assets/packages/<name>/`. False positive.

### Still fragile, not changed

`borders` (7 keys) and `book` (12 keys) still throw on any missing key. Every bundled theme satisfies
them, so nothing is broken today, but a community theme that omits one `book` colour will vanish the
same way these ten did. Worth the same treatment if you ever see a Theme Store entry fail to save.

## Remaining gap, measured (not estimated) — after analyze run 7 came back clean

Upstream `lib/` holds **697** Dart files; Voltix holds **580**. **161 upstream files have no
counterpart in Voltix.** Grouped by what they actually build:

| Area | Files | Status |
|---|---:|---|
| Books / audiobooks / reader | ~40 | **Absent entirely.** No book screens, widgets, view models or services exist in Voltix |
| Games / emulator | ~25 | Blocked on the native libretro backend |
| Offline catalog | ~14 | Voltix has downloads but no `lib/data/offline` layer |
| Seerr remainder | 11 | collection screen + view model, issues view model, 6 widgets, notification service |
| Platform integrations | ~12 | CarPlay, MPRIS, Android Auto / TV Channels, Watch Next, push + Firebase, Apple TV backend, Aether |
| Live TV EPG subsystem | 7 | Voltix has its own guide screen — divergence rather than a gap |
| Modern detail screen | 6 | needs the `DetailScreenStyle` enum and `ItemDetailViewModel.seerr` |
| Gamepad / focus | 6 | 4 gamepad + `row_focus_coordinator` + `siri_remote_glide` |
| Admin library screens | 5 | display, metadata, NFO + 2 widgets |
| Misc widgets | ~15 | `quick_return_wrapper`, `identify_dialog`, `sliding_pill_tabs`, `app_update_banner` and similar |

Not file-shaped, still open:

- `DetailScreenStyle` enum — the classic/modern toggle the modern detail screen reads
- `PassthroughCodec` — needs your decision; Voltix has a `truehd` member upstream lacks, so a naive
  port loses Atmos handling
- `seerrBlockNsfw` vs Voltix's `jellyseerrBlockNsfw` — a migration, not a rename
- 23 default-value drifts — decisions, not code
- `adaptiveListSection` on 6 header-interleaved screens — hand work, Apple-idiom cosmetics only
- `borders` (7 keys) and `book` (12 keys) theme parsing still throw on a missing key, the same way
  `semantic` did before the themes fix. Nothing bundled trips it; a community theme could

### Correction to my own measurement

The enum comparison reported `GlassQualityMode` as 16 members upstream and **0** in Voltix. That was
my regex, not the code: Voltix declares it on one line as
`enum GlassQualityMode { auto, full, reduced }`, with no parenthesised members for the pattern to
count. It is present. The same script reported "1 preference" on both sides, which is also its own
failure rather than a finding — the preference declaration style does not match what it looked for.
Real enum gaps are `DetailScreenStyle` and `PassthroughCodec`, both listed above.

## Tranche 16 — the Seerr remainder

Gap-mapped all 10 remaining Seerr files **before** writing anything, which is the habit the 439-error
run bought. The whole prerequisite set came to: 16 l10n keys, one unrelated widget
(`floating_notification.dart`), and one route. Nothing else was missing.

### Ported (11 files)

| File | Lines |
|---|---:|
| `ui/widgets/floating_notification.dart` | 192 |
| `ui/widgets/quick_return_wrapper.dart` | 288 |
| `ui/widgets/seerr/seerr_text_field.dart` | 94 |
| `data/viewmodels/seerr_collection_view_model.dart` | 210 |
| `data/viewmodels/seerr_issues_view_model.dart` | 326 |
| `ui/widgets/seerr/seerr_cancel_request_dialog.dart` | 69 |
| `ui/widgets/seerr/seerr_manage_requests_sheet.dart` | 108 |
| `ui/widgets/seerr/seerr_report_issue_dialog.dart` | 250 |
| `data/services/seerr_notification_service.dart` | 124 |
| `ui/screens/seerr/seerr_collection_screen.dart` | 614 |
| `ui/widgets/seerr/seerr_collection_banner.dart` | 159 |

Plus `Destinations.seerrCollectionDetail` + the `seerrCollection(id)` helper, and the
`GoRoute` in `app_router.dart` placed where upstream has it.

### l10n, second pass

16 more keys across all 59 generated files and 68 arb files, this time with the three-shape extractor
and per-class insertion from the start. `app_en.arb`: 2440 -> 2456. The duplicate-member check ran as
part of the same script rather than after the fact, and came back clean.

### `seerr_collection_banner.dart` is unparked

It was the one file Tranche 15 could not place. It came out of `_parked_2_4/` only after asserting the
parked copy was byte-identical to upstream's, so nothing silently drifted while it sat there.

### `_parked_2_4/` is now honest

It held 21 copies of files that had already been ported, which made the folder useless as a to-do
list. Those are archived under `_parked_2_4/_ported/`. What remains parked is exactly:

- `ui/widgets/seerr/seerr_item_status.dart` — waits on `ItemDetailViewModel.seerr`
- the 6 `_pending_modern_detail/` files

### Verification

All relative imports resolve across the 11 new files. Every app-namespaced type they reference is
declared somewhere in `lib/` or `packages/` (the only unresolved names are Flutter SDK types and words
picked out of doc comments). Bracket balance holds across 72 touched Dart files.

Structural only, as always. What it cannot check is argument-list drift: the collection screen calls
Voltix's `LibraryRow`, `MediaCard`, `NavigationLayout` and `TrackSelectorDialog`, and those are the
most likely place for this tranche to break. **Needs `flutter analyze`.**

## Tranche 17 — modern detail prerequisites

Gap-mapped the whole modern-detail set first. It needed 58 l10n keys, `Destinations.studio`, and
`ItemDetailViewModel.seerr`. **All seven files are now free of prerequisite gaps.**

### Three more of my own measurements were wrong

Before doing any work I re-checked the earlier "what's left" figures, and the enum comparison script
had been lying three separate times:

| I reported | Truth |
|---|---|
| `GlassQualityMode` 16 members upstream, 0 in Voltix | present in Voltix |
| preferences: 1 upstream, 1 in Voltix | the regex never matched the declaration style |
| `DetailScreenStyle` absent from Voltix | **already present**, `preference_constants.dart:620` |

The cause: `enum (\w+) \{(.*?)\n\}` with `re.S`. Because `.` matches newlines, one match can run
across a later enum's boundary and swallow it, so any enum written without parenthesised members
disappeared from the count. `^enum (\w+)\b` with `re.M` gives 57 upstream / 58 Voltix and the only
real gap is **`PassthroughCodec`**. Every preference the settings screen needs — `detailScreenStyle`,
`detailExpandedTabs`, `detailShowTechnicalDetails`, `detailsBackgroundBlurAmount`,
`recommendationSystemSource`, `recommendationsApplyParentalRatingCap` — already existed.

### l10n: 58 keys, and a branding decision

`app_en.arb` 2456 -> 2514, across all 59 generated files and 68 arb files.

Voltix's l10n contains **zero** "Moonfin" and 41 "Voltix", so the fork rebrands user-facing strings
and these had to be rebranded rather than copied. Four values carried the upstream brand:
`detailScreenStyleSubtitle`, `recommendationSystemMoonfin`, `recommendationSystemSubtitle`, and —
which I initially missed — `recommendationsApplyParentalRatingCapSubtitle`. My brand check caught the
fourth; 62 generated lines and 61 arb values needed a second pass.

Then one last leak the refined check found: **`app_zh.arb` renders the Classic option's label as the
literal string "Moonfin"** rather than a translated word, so Chinese users would have seen an option
named after the upstream project. Now "Voltix".

Worth noting the check had to be narrowed to look *inside string literals*: matching whole lines
flagged `detailScreenStyleMoonfin`, whose identifier contains the brand but whose value is "Classic".
An identifier is not a leak.

### `Destinations.studio` was not a one-liner

`modern_detail_content.dart` links a studio chip through `Destinations.studio(name)`, and upstream
routes that to `LibraryBrowseScreen(studioName: ...)`. Voltix's browse screen and view model had
`genreName`/`genreId` but no studio equivalent, so the route needed threading through both:

- `library_browse_view_model.dart` — the `studioName` field, `isStudioBrowse` / `isFilterBrowse`,
  the constructor, `_prefKey` (so a studio view keeps its own sort and layout rather than sharing the
  library's), the `studios:` query, and **both** `getItems` calls in `_fetchItemsWithFallback` — the
  primary and the 5xx retry. Missing the retry would have made a studio browse silently fall back to
  an unfiltered library on any server hiccup.
- `library_browse_screen.dart` — the widget parameter, and `overrideName` falling back to the studio
  name so the screen has a title.
- `Destinations.studioBrowse` + `studio()`, and the `GoRoute`.

`packages/server_core`'s `itemsApi.getItems` already accepted `studios:`, so nothing was needed there.

### `ItemDetailViewModel.seerr` — the overlay, not the whole thing

Upstream's Seerr slice on this view model is two features. Only one was ported:

**Ported — the overlay.** `_seerr` + its accessor, `_ensureSeerr()`, `_loadSeerrOverlay()`, the
`unawaited(...)` kick-off in `_loadSecondary` (deliberately outside the `Future.wait`, so a slow Seerr
server never delays library content that has already arrived), and disposal of the child — which
matters, because the child owns a periodic download-poll timer that would otherwise outlive the
screen.

**Deferred — Seerr-only mode.** `_loadSeerrOnly`, `TmdbItemRef`, `_seerrRawData`, `_seerrSeasons`,
`isSeerrOnly`, `seerrResolvedLibraryId`. That is the separate feature of opening a title that is
*not in the library at all* and building the screen out of what Seerr knows. It needs `TmdbItemRef`,
which Voltix does not have, and it belongs with the modern screen's `tmdb:` route branch.

`seerr_item_status.dart` is unparked. Every import resolves and every state member it reads exists.

### What is left of the modern detail screen

Only `_pending_modern_detail/` (6 files) plus the `item_detail_screen.dart` diff — 14 private widgets
that upstream made public with changed signatures (`DetailActionButtons` gains `modernStyle`,
`fullWidthPrimary`, `maxVisibleButtonsOverride`, `onArrowRightAtEnd`). That is hand work on a file
Voltix has diverged, and it is the one part of this no script should touch.

### Verification

Bracket balance holds across 65 touched Dart files. No duplicate l10n member in any class. All 68 arb
files parse. No "Moonfin" survives in any generated string literal or arb value.

**Two tranches are now stacked without an analyze run (16 and 17).** That is against my own advice and
worth undoing at the first opportunity — if something breaks, the blame is split across ~90 files
rather than pinned.

## flutter analyze — run 8 (26 errors). All from Tranche 16, and two were holes in my checker.

Stacking 16 and 17 without an analyze between them cost nothing in the end — every error traced to 16
— but that was luck, not design.

### Cause 1 (11 errors): my import check ignored bare same-directory imports

`seerr_notification_service.dart` opens with:

```dart
import 'local_notification_bootstrap.dart';
```

My checker matched `import '((?:\.\./|\./)[^']+)'` — it **required** a `./` or `../` prefix, so a
bare same-directory import was invisible. That let Tranche 16 ship a file whose dependency was never
even looked for. `local_notification_bootstrap.dart` (366 lines) is now ported, and it pulled in
`playback/headless_session_bootstrap.dart` (118) behind it — found by running a proper transitive
closure rather than a one-level check.

### Cause 2 (12 errors): I never checked method existence on classes that already exist

The two new view models call nine `SeerrRepository` methods Voltix did not have: `getIssues`,
`getIssueCount`, `getIssue`, `commentOnIssue`, `setIssueStatus`, `deleteIssue`, `getCollectionDetails`,
`getMediaSummary`, `invalidateBadgeCount`. My gap-map checked imports, l10n keys and route
destinations — never whether a method being *called* on an existing class was defined. This is the
same blind spot that produced the 439-error run, in a new costume.

Added to the client: `getRequestCount`, `getCollectionDetails`, `getIssues`, `getIssueCount`,
`getIssue`, `commentOnIssue`, `setIssueStatus`, `deleteIssue`, `retryRequest` — with Voltix's CSRF
handling on the mutations, which upstream 2.4 dropped. Added to the repository: those, plus
`getActionableBadgeCount` and the `_mediaSummaryCache`.

`invalidateBadgeCount()` needed a judgement call: Voltix has no badge-count machinery, so it could
have been a no-op stub. A stub that silently does nothing is the sort of thing that gets found a year
later, so `getActionableBadgeCount` came across with it. The pair is coherent and the private fields
are actually read.

### Cause 3 (2 errors): my l10n check missed one access style

`AppLocalizations.of(context).manageRequests` — no `!`. My pattern covered `l10n.x` and
`AppLocalizations.of(context)!.x` but not the unwrapped form. Both keys ported; `app_en.arb` 2514 ->
2516.

### Cause 4 (1 error): the argument drift I predicted

`Destinations.seerrMedia` takes `(String itemId)` in Voltix and
`(String itemId, {String? mediaType, String? title})` upstream, which passes them as query
parameters. Voltix's version now matches upstream — the 8 existing call sites pass one positional
argument and are unaffected.

The route also had to read them. Voltix's detail screen reads `mediaType` off the `extra` map (which
its own call sites populate), upstream reads query parameters. It now reads **both**, so neither path
breaks.

### The checker is fixed

Bare same-directory imports, transitive closure rather than one level, both `AppLocalizations` access
styles, and method existence against the methods actually declared on the repository. Re-run over all
14 files from tranches 16 and 17: **0 problems**. Bracket balance holds across 66 files.

Worth being blunt about the pattern: every one of my structural checks has passed right up until the
analyzer disagreed, and in each case the check was narrower than the thing it claimed to verify.
`flutter analyze` is the only real gate here, and my "verified" should be read as "nothing I know how
to look for is wrong".

## Tranche 18 — the settings menu wiring. You were right to ask.

Auditing what the settings panel actually *reaches* rather than what exists on disk turned up a real
hole, and it was in work I had already reported as done.

### The finding

All 28 upstream `settings/panel/*.dart` files exist in Voltix, so a file-level check said parity. But
the **External Home Rows hub was missing three of its five entries**, and two of the screens behind
them had never been built at all:

| Entry | Was |
|---|---|
| IMDb Lists | present |
| TMDB Lists | present |
| Custom Home Rows Wizard | present |
| **Upcoming Calendars** | **screen did not exist** |
| **Seerr Lists** | **screen did not exist** |

This mattered more than a missing screen usually would. Tranche 9 wired the Radarr/Sonarr calendar
rows and all 12 Seerr rows into `home_view_model.dart` — 641 lines of calendar merge logic among
them — and I reported that as complete. It was, in the sense that the rows load. But **there was no
way for a user to switch any of them on.** Working code with no route to it.

### Ported

- `_UpcomingCalendarsScreen`, `_SeerrListsScreen`, `_SeerrRowSwitchTile` — 345 lines, appended to
  `external_lists_screen.dart` (they belong to the same part library, so the private helpers they
  share were already in scope)
- the two hub tiles, plus the `_checkServices()` probe behind `showUpcomingCalendars` so Upcoming
  Calendars only appears when the server really has a Radarr or Sonarr configured
- shell imports: `seerr_repository.dart`, `seerr_row_config.dart`
- `SeerrPreferences.homeRowsConfig` / `setHomeRowsConfig` / `_homeRowsConfigFromSections` /
  `isSeerrHomeRowEnabled`. Upstream keeps two separate row configs — `rows_config` for the Seerr
  discover screen and `home_rows_config` for the home screen — and Voltix only had the first. The
  fallback path matters on upgrade: with `home_rows_config` never written, it derives from the old
  `home_sections_config` so a user's existing choices survive
- `SeerrRowTypeHomeSection` and `HomeSectionTypeSeerrRow` extensions (verified exhaustive: all 12
  `SeerrRowType` members covered)
- 8 l10n keys: `yourWatchlist`, the six `imdb*` chart names, `externalLists`

### Settings search was missing the whole area

Voltix's search index had **no** External Lists sections at all — not the hub, not IMDb, TMDB, custom
rows, calendars or Seerr lists. Ported the six sections and upstream's 102-line leaf group (gated on
`seerrAvailable`, as upstream gates it).

That needed `_SearchSection.leaf()` to gain `subtitle` and `header`, which Voltix's generated version
lacked. `header` is load-bearing here: the nine calendar switches group under "Radarr" and "Sonarr",
and without it they read as nine unrelated toggles in search results.

Kept Voltix's `>` breadcrumb separator rather than upstream's `›` — changing it would restyle all 108
existing leaves, which is a cosmetic decision for you rather than part of this fix.

### A bug of mine, found on the way

`SeerrRowConfig.defaults()` had **two rows at `order: 1`**. When I added `yourWatchlist` in an earlier
tranche I inserted it at order 1 without renumbering, so it collided with `recentlyAdded` and the
whole list sat one behind upstream. Re-numbered to match. Sorting on a duplicate order is
arbitrary-but-stable, which is exactly the kind of thing that looks fine until it doesn't.

### Not gaps, on inspection

- `DownloadSettingsScreen` is orphaned in Voltix — but deliberately: the fork pushes its own
  `_OfflineDownloadsScreen` from the same slot. The old file is dead code, worth deleting, not porting.
- `AboutScreen` and `NavigationSettingsScreen` are unreachable in Voltix; upstream does not push them
  either. Dead on both sides.
- `DownloadedGamesScreen` / `EmulatorCoresScreen` — games, still blocked on native libretro.

### And another correction to my own tooling

My first pass reported `_TmdbListsScreen` as declared-but-never-pushed. It **is** pushed — the call is
just split across lines by the formatter:

```dart
onTap: tmdbAvailable
    ? () => context.pushSettingsScreen(
        const _TmdbListsScreen(),
      )
```

`pushSettingsScreen\(\s*const (\w+)\(` without `re.S` could not see it. That is the fifth regex of
mine to give a wrong answer in this port; the audit was re-run multiline-tolerant before I acted on
any of it. Two of the five nearly caused real damage.

## Tranche 19 (analysis only) — the modern detail screen is bigger than I said

Before writing anything I measured the real gap, and two of my earlier statements were wrong.

### Correction 1: nothing needs making public

I said "14 private widgets need making public with changed signatures". Wrong. **All 12 classes the
modern layouts construct are already public in Voltix** — `DetailActionButtons`, `DetailCastRow`,
`DetailChaptersRow`, `DetailEpisodeCard`, `DetailFeaturesRow`, `DetailSimilarRow`, `DetailTrackList`,
`ExpandableBiography`, `FilmographyRow`, `PersonDates`, `SeerrAppearancesRow`, `SeerrCrewCreditsRow`.

### Correction 2: the constructor drift is one parameter, not four

I said `DetailActionButtons` needed `modernStyle`, `fullWidthPrimary`, `maxVisibleButtonsOverride`
and `onArrowRightAtEnd`. **All four already exist on Voltix's constructor.** Across all 12 classes the
only upstream parameter Voltix lacks is `DetailTrackList.showAlbum`, and the modern layouts never
pass it.

### What is actually wrong: the parameters are inert

| Parameter | upstream uses | Voltix uses |
|---|---:|---:|
| `modernStyle` | 17 | 2 (declaration + ctor only) |
| `onArrowRightAtEnd` | 7 | 2 |
| `maxVisibleButtonsOverride` | 4 | 2 |
| `fullWidthPrimary` | 3 | 2 |

Voltix declares all four and reads none of them. The behaviour lives in `DetailActionButtonsState`,
and that is where the real divergence is:

- upstream: **4,497 lines**
- Voltix: **3,099 lines**
- 56% of upstream's lines appear identically; **186 change hunks**; upstream has **1,961 lines Voltix
  lacks**, Voltix has 563 upstream lacks
- only **38** of Voltix's lines relate to the button-layout work added earlier in this port

So Voltix's copy is not "upstream plus my changes" — it is roughly 1,900 lines behind upstream on the
single most complex widget in the app. Patching the ~21 `modernStyle` sites would make the modern
layout *look* right while leaving all of that missing.

### What a wholesale replacement drags in

Upstream's `DetailActionButtonsState` references:

- **the five `seerr*` `DetailButton` members** (`seerrRequest`, `seerrRequest4k`, `seerrWatchlist`,
  `seerrManage`, `seerrReportIssue`) — 18 references. I deliberately omitted these from Voltix's enum
  and documented why: Voltix's detail screen rendered none of them. Upstream's **does**, so the
  omission has to be reversed.
- **`ItemDetailViewModel.isSeerrOnly`** — 3 references. Part of the Seerr-only mode deferred in
  Tranche 17, which also needs `TmdbItemRef`, `_loadSeerrOnly`, `_seerrRawData`, `_seerrSeasons`.

### The rest of the wiring, which is small either way

- the `DetailScreenStyle.modern` branch itself is one ternary in `_ItemDetailScreenState`
- `_showNavbar` and `_actionsExpanded` state — absent from Voltix (0 references)
- `viewModel.load(mediaSourceId: id)` — Voltix's `load()` takes no arguments
- the 6 `_pending_modern_detail/` files

### One consequence worth flagging whichever way this goes

`onArrowRightAtEnd` is how focus **leaves** the action row on TV. If the modern layout ships with that
parameter still inert, a TV user may not be able to move right off the button row. A modern layout
with a focus trap is worse than no modern layout, so this cannot be left half-done on TV.

Not proceeding until the scope question is answered — this is the most complex widget in the app and
the choice reverses a documented earlier decision.

### Decision taken: full replacement, one tranche at a time

You chose the full replacement of `DetailActionButtonsState` plus the five `seerr*` detail buttons,
and one-tranche-then-analyze from here. **Tranches 16, 17 and 18 are still unverified, so nothing new
is being written until they come back clean.** Below is the execution plan, so the next turn is
mechanical rather than exploratory.

### Prerequisite map (measured, no files touched)

**A. The five `seerr*` `DetailButton` members**

| member | icon | l10n key | key present |
|---|---|---|---|
| `seerrRequest` | `Icons.add` | `request` | yes |
| `seerrRequest4k` | `Icons.add` | `request4k` | yes |
| `seerrWatchlist` | `Icons.bookmark_border` | `watchlist` | **missing** |
| `seerrReportIssue` | `Icons.report_problem_outlined` | `reportIssue` | yes |
| `seerrManage` | `Icons.rule` | `manageRequests` | yes |

Only one l10n key to add. Note the enum-exhaustiveness lesson from run 2: adding five members to
`DetailButton` will break every exhaustive switch over it, and only the compiler can find them.

**B. Seerr-only mode** — nothing of it exists in Voltix except the `isSeerrOnly` name:

`_loadSeerrOnly`, `_isSeerrOnly`, `_seerrResolvedLibraryId` + accessor, `_seerrOnlyTitle` + setter,
`_seerrRawData`, `_seerrSeasons`, plus `lib/data/models/tmdb_item_ref.dart` (`TmdbItemRef`,
`TmdbItemKind`), which Voltix does not have at all.

**C. The modern branch in `_ItemDetailScreenState`**

- `_showNavbar`, `_actionsExpanded` — absent (0 references)
- `_playFromChapter`, `_ensureInitialFocusNode`, `_onBackdropItemFocused` — all present
- `viewModel.load(mediaSourceId:)` — **Voltix's `load()` takes no arguments**, so the media-source
  switch callback needs that parameter threaded in

**D.** The 6 `_pending_modern_detail/` files, and `DetailTrackList.showAlbum` (unused by the modern
layouts, but the one genuine constructor gap).

### Execution order for the next tranches

1. `tmdb_item_ref.dart` + Seerr-only mode on `ItemDetailViewModel` + `load(mediaSourceId:)` — analyze
2. `watchlist` l10n key + the five `seerr*` `DetailButton` members + every exhaustive switch the
   compiler then flags — analyze
3. `DetailActionButtonsState` replaced wholesale, with the 38 lines of button-layout work re-applied
   on top — analyze
4. the 6 modern files + `_showNavbar` / `_actionsExpanded` + the `DetailScreenStyle.modern` ternary —
   analyze

Step 3 is the risky one and it goes in alone. Step 2 before it, because the replacement will not
compile without those five members.

## flutter analyze — run 9 (20 issues). Only one was mine.

**Something other than me has been editing this tree.** Between roughly 14:02 and 14:57 today, a set
of changes landed that I did not make. My own work today is stamped 20:23-20:28.

Changed by the other party:

- the 6 modern detail files **copied into `lib/ui/screens/detail/modern/`** (byte-identical to the
  parked copies — the parked originals are still in place)
- new: `admin_library_display_screen.dart`, `admin_library_metadata_screen.dart`,
  `admin_library_nfo_screen.dart`, `admin_form_styles.dart`
- modified: `admin_drawer.dart`, `admin_shell_screen.dart`, `aggregated_item.dart`,
  `top_toolbar.dart`, `platform_detection.dart`, `focus/step_scroll.dart`, `navigation_layout.dart`,
  `item_detail_view_model.dart`, `tmdb_repository.dart`, `item_detail_screen.dart`,
  `focusable_toolbar_button.dart`

**Checked first: nothing of mine was clobbered.** The Tranche 17 Seerr overlay is intact in
`item_detail_view_model.dart` despite that file being edited at 14:54, and every Tranche 17/18 file
and symbol is still present.

### The one error that was mine

`settings_search_index.dart:476` — `tmdbAvailable` undefined. I ported upstream's leaf group including
its `if (tmdbAvailable)` gate but not the local the gate reads. Upstream declares `seerrAvailable` and
`tmdbAvailable` together; I took one and left the other. Added.

### The four that were not

- **3 errors** — `adminDrawerDisplay`, `adminDrawerMetadata`, `adminDrawerNfo` missing, needed by the
  new admin library screens. All three exist upstream, so they went in the normal way (59 generated
  files, 183 arb entries). `app_en.arb` 2524 -> 2527.
- **1 error** — `DetailSimilarRow` declared `final VoidCallback? onNavigateUp` without adding it to
  the constructor. A nullable final still has to be initialised. Added `this.onNavigateUp,`. This is a
  Voltix-side field with no upstream counterpart, so it came from the other party's work; the fix is
  the minimal one and does not change their intent.

### 15 infos left, none mine and none blocking

14 × `use_key_in_widget_constructors` and 1 × `unnecessary_underscores` in `item_detail_screen.dart`,
plus 1 × `use_null_aware_elements` in `modern_landscape_layout.dart`. All in the other party's files
or in the modern files they moved. Left alone deliberately — silently tidying someone else's
in-progress work invites a merge conflict for no functional gain.

### This changes how the next tranche has to be approached

The plan was to replace `DetailActionButtonsState` wholesale — 4,497 lines in the single most complex
file in the app. **`item_detail_screen.dart` was modified by the other party at 14:57**, and the
modern files are now in `lib/`, which suggests they are working on exactly the same thing.

Two hands rewriting that class at once will produce a mess neither can untangle. Before I start,
I need to know whether that work is mine to do.

## Tranche 20 — the modern screen was compiling against hollow stubs

You said the modern detail screen is mine. First thing I found on picking it up is worth stating
plainly: **the other party's copy of the modern files into `lib/` was made to compile by adding
thirteen hollow members to `ItemDetailViewModel`.**

```dart
List<AggregatedItem> get playlistItems => [];
bool get playlistLoadingMore => false;
bool get isSeerrOnly => false;
String? get effectiveSeasonId => null;
void reorderCollectionPlaylistItem(int oldIndex, int newIndex) {}
List<AggregatedItem> get seriesEpisodes => [];
Future<void> loadAllSeriesEpisodes() async {}
List<ParentCollection> get parentCollections => [];
CollectionSortOption get collectionSort => CollectionSortOption.releaseAscending;
Future<void> setCollectionSort(CollectionSortOption option) async {}
bool get playlistIndexBuilding => false;
Future<void> loadMoreCollectionItems() async {}
Future<void> loadMorePlaylistItems() async {}
```

The type checker was satisfied and the screen would have shown empty playlists, no series episodes,
no parent collections, no collection sorting and no season expansion — silently, with nothing in the
log. Exactly the failure mode I flagged when I refused to stub `invalidateBadgeCount` in Tranche 16.

### What was actually ported

The closure of those thirteen came to **344 lines across 42 members**, not the 946-line whole-file
gap — so this was additive rather than a replacement, which meant the fork's own work survived by
construction rather than by me remembering to re-apply it.

- `_PlaylistItemIndexEntry` (33 lines, top-level) — the lightweight index entry
- 28 new private members: the playlist index (`_playlistIndexEntries`, `_ensurePlaylistIndexEntries`,
  `_rebuildFlattenedIds`, `_flattenedIds`, `_customOrderIds`), collection and playlist paging
  (`_fetchCollectionPage`, `_fetchPlaylistPage`, `_collectionPageSize`, `_playlistPageSize`, the
  fetched/total/hasMore counters), `_resolveNextUp`, `_resolvedEpisodesSeasonId`,
  `_seriesEpisodesRequested`, `_isSeerrOnly`, `_collectionSort`, `_parentCollections`
- all thirteen stubs replaced with upstream's real bodies
- `_buildPlaylistIndex` (37 lines) — the initialiser, which reads a saved custom order from the
  plugin and otherwise builds the index and sorts by release date
- `PluginSyncService.fetchCustomCollectionOrder` — 20 lines, absent from Voltix, hits
  `/Moonfin/Collections/{id}/Order` (the namespace already confirmed by curl earlier in this port)

### The part that would have stayed broken without checking

Porting the members alone was not enough: three of the loaders were **declared but never called**.
Comparing call-site counts against upstream found it — `_resetPlaylistPaging`,
`_ensurePlaylistIndexEntries` and `_fetchCollectionPage` each had one fewer call site than upstream,
because the two entry points live in code Voltix had diverged: `_buildPlaylistIndex` (absent) and
`_loadCollectionItems` (the fork's own single-shot version). Both are now wired, and the BoxSet branch
of `_loadSecondary` kicks off the index alongside the grid, as upstream does.

All seven ported loaders now match upstream's call-site count exactly.

### One deliberate merge rather than a copy

Upstream's `_fetchCollectionPage` asks for `PrimaryImageAspectRatio,BasicSyncInfo,People`. The fork's
single-shot loader asked for a much wider set — overview, production year, premiere date, community
rating — because the fork's collection grid displays them. Taking upstream's paging verbatim would
have paged correctly and quietly dropped that metadata from the grid. The page request now carries
the fork's field list plus its `enableImageTypes`/`imageTypeLimit`, and `_fetchPlaylistPage` keeps its
own narrower list (asserted separately, since the two shared an identical `fields:` line and a
careless replace would have hit both).

`reorderCollectionPlaylistItem` also changed from `void` to `Future<void>`, matching upstream.

### Verification

Every private referenced is declared. All 40 view-model members the modern files read now resolve.
Bracket balance holds on both files. Fork-specific work confirmed still present:
`_findParentCollectionByScanningBoxSets`, the wider `_episodeOverviewFields`, the local
recommendation path, `directors`/`writers`, `deleteItem`, and my Tranche 17 Seerr overlay.

Backup at `item_detail_view_model.dart.bak-vmparity`.

**One tranche, stopping here for `flutter analyze` as agreed.** Next is the `DetailActionButtonsState`
replacement, which still needs the five `seerr*` members and Seerr-only mode ahead of it.

## flutter analyze — run 10 (3 errors, all mine, all in Tranche 20's ported code)

### The two undefined names

- **`contextSeasonId`** (2 sites) — upstream's `effectiveSeasonId` reads a constructor field Voltix
  never had. It keeps an episode list anchored to the season the viewer arrived from rather than
  jumping to the series default. Added as an optional field + constructor parameter, so the single
  construction site is unaffected.
- **`PluginSyncService.saveCustomCollectionOrder`** — I ported `fetchCustomCollectionOrder` for
  `_buildPlaylistIndex` and missed its write counterpart, which `reorderCollectionPlaylistItem`
  needs. Both halves of the endpoint pair are now there.

### The two "infos" were the real finding

`prefer_final_fields` on `_isSeerrOnly` and `_parentCollections` is the analyzer saying **nothing ever
assigns them** — which means those two members were still hollow after Tranche 20, exactly the thing
that tranche existed to fix. A lint I could have silenced by writing `final` instead of reading what
it was telling me.

- **`_parentCollections` — fixed properly.** Upstream and the fork both have a method called
  `_loadParentCollection`, but they model the result differently: the fork resolves one parent box set
  into `_parentCollectionName` + `_parentCollectionItems` (which its classic screen reads), while
  upstream builds a `List<ParentCollection>` (which the modern layouts read). Replacing the fork's
  loader would have fixed the modern screen and broken the classic one, so the fork's result is now
  also published in list form. Both consumers work off one fetch.
- **`_isSeerrOnly` — still `false`, and that is honest rather than hollow.** It is only ever set by
  `_loadSeerrOnly`, which is Seerr-only mode, deferred to the next tranche by plan. The field reflects
  a mode that does not exist yet; making it `final` to quiet the lint would have hidden that. The info
  stays until the mode lands.

### Remaining 17 infos: not mine

14 × `use_key_in_widget_constructors`, 1 × `unnecessary_underscores`, 1 × `use_null_aware_elements` —
all in `item_detail_screen.dart` and `modern_landscape_layout.dart`, both of which the other party is
working in. Still leaving them alone.

**Zero errors expected on the next run.** Next tranche: `TmdbItemRef` + Seerr-only mode, which will
also make `_isSeerrOnly` meaningful and clear that last info.

## Tranche 21 — Seerr-only mode, and the five seerr buttons

### First, a finding about the modern files

They are in `lib/ui/screens/detail/modern/` but **nothing imports them.** The other party copied them
in and added the thirteen hollow view-model members so that six *orphaned* files would type-check. The
modern detail screen is not merely unstyled — it is not reachable at all. Wiring the
`DetailScreenStyle.modern` branch is deliberately the last step, after the action row works, so it is
not switched on with a focus trap on TV.

### Ported

- `lib/data/models/tmdb_item_ref.dart` (54 lines, no imports) — `TmdbItemRef` / `TmdbItemKind`
- Seerr-only mode on `ItemDetailViewModel`: `_loadSeerrOnly` (41), `_seerrRawData` (44),
  `_seerrSeasons` (14), `_seerrResolvedLibraryId`, `seerrResolvedLibraryId`, `_seerrOnlyTitle`,
  `seerrOnlyTitle`. `_isSeerrOnly` is now actually assigned, so the `prefer_final_fields` info from
  run 10 is gone and the member is no longer hollow.
- `load({String? mediaSourceId})` — the `tmdb:` dispatch, and **the paging resets**
- `getItem(mediaSourceId, fields)` threaded through `server_core`'s abstract `ItemsApi` and both
  implementers, `JellyfinItemsApi` and `EmbyItemsApi`. `UserLibraryApi.getItem` is a separate
  interface and was left alone.
- the five `seerr*` `DetailButton` members, plus `availableInSeerrOnly`, and `isOffered` /`icon`/
  `label` arms. Both exhaustive switches carry all 22 members; the two with defaults still have them.
- l10n `watchlist`

### A bug Tranche 20 introduced, found here

Voltix's `load()` did not reset the paging counters — because until Tranche 20 there were none. Every
re-entry (which is exactly what switching media source does) would have appended a fresh first page
onto the previous run's items and mis-reported `hasMore`. Invisible on first load, wrong on every
subsequent one. Now cleared, all thirteen fields.

### `mediaSourceId` was not made a hollow parameter

`load(mediaSourceId:)` is what the modern layout's media-source switch calls. Accepting it and
ignoring it would have compiled and silently reloaded the wrong source, so the parameter goes all the
way down: view model → `ItemsApi.getItem` → the Jellyfin and Emby query strings. Three packages
changed rather than one signature faked.

### A correction: my extractor truncated a member

`_seerrSeasons` came across as **5 lines instead of 14** on the first attempt. Its body is
`=> [ ... ]` containing `'${itemId}:s${season.seasonNumber}'` — my `end_of()` counted braces in raw
text, so the `{` and `}` of string interpolation looked like code structure and closed the member
early. The bracket-balance check caught it (`()` and `[]` each off by one) and the file was restored
from `.bak-seerronly` and redone with a literal-blanking extractor that also asserts each extracted
member is itself balanced.

Worth noting what nearly happened: braces alone still balanced and brace depth still returned to zero,
so a brace-only check would have passed a file with a truncated method in it.

### One transient state, deliberately

The detail-button settings screen filters on `isOffered`, and the five new members are gated on
`seerrAvailable` — so on a server with Seerr they now appear as five switches that reorder buttons
which do not render yet. The widgets come with the `DetailActionButtonsState` replacement, the next
tranche. Flagging it rather than temporarily forcing `isOffered` false, which would be a hack removed
one tranche later.

Backups: `.bak-seerronly`, `.bak-vmparity`.

## flutter analyze — run 11: zero errors. All 19 infos fixed.

The enum addition landed clean — no non-exhaustive switch anywhere, which was the risk.

| Count | Lint | Fix |
|---:|---|---|
| 13 | `use_key_in_widget_constructors` | `super.key` added to `DetailActionButtons`, `DetailCastRow`, `DetailSimilarRow`, `DetailFeaturesRow`, `DetailChaptersRow`, `DetailEpisodeCard`, `PersonDates`, `PersonDatesVertical`, `ExpandableBiography`, `FilmographyRow`, `SeerrAppearancesRow`, `DetailTrackList`, `SeerrCrewCreditsRow` |
| 4 | `use_null_aware_elements` | `'ProductionYear': ?year`, `'mediaSourceId': ?mediaSourceId` (Emby + Jellyfin), `?aboveHero` |
| 1 | `unnecessary_brace_in_string_interps` | `'${itemId}:s…'` -> `'$itemId:s…'` |
| 1 | `unnecessary_underscores` | `(_, __)` -> `(_, _)` |

Two of the null-aware ones and the brace were mine, from the `getItem` threading and `_seerrRawData`.
The 13 missing keys and the underscore pair were pre-existing or the other party's; fixed on your
instruction rather than left as cross-contamination.

Checked rather than assumed: every one of the 13 classes extends `StatelessWidget` or
`StatefulWidget` (so `super.key` is valid), none now declares both `super.key` and an old-style
`Key? key`, and all five touched files still bracket-balance. Backup at `.bak-keyfix`.

Left alone deliberately: `if (mediaSourceId != null) 'MediaSourceId': …` in
`packages/server_core/lib/src/models/playback_models.dart` (4 sites) and one in `playback_manager.dart`.
The analyzer did not flag those, so whatever distinguishes them from the two I changed, changing them
would be guessing at a rule I have not confirmed.

## Tranche 22 — STOPPED. I gave you bad information, and the approved plan is wrong.

You approved the full replacement of `DetailActionButtonsState` on the strength of my measurement:

> only **38** of Voltix's lines relate to the button-layout work added earlier in this port

That number was literally true — 38 lines mention `DetailButton` / `detailButtonLayout` — and I
presented it as if the remaining Voltix-only lines were noise. **They are not.** Diffing the two class
bodies hunk by hunk (upstream 4,022 lines, Voltix 2,671) gives **47 Voltix-only hunks**, and only four
of them are the button-layout work. Sampling the rest:

| Voltix-only | What it is | Upstream |
|---|---|---|
| `_checkOffline`, `_offlineRow`, `_offlineQueue`, `OfflineRepository` | offline playback for a downloaded item, season or series | **0 lines — entirely the fork's** |
| `_isSdhSubtitleStream`, `_isExternalSubtitleStream`, the scoring loop | SDH vs external subtitle preference, scored on `preferSdh`, embedded-over-external, `IsDefault`, stream order | replaces 13 upstream lines with ~59 |
| queue resume block | all-watched / all-unwatched / resume-position / next-unwatched start selection | **0 lines** |
| `_openAudioSelector`, preferred-language matching | audio track auto-selection | diverged |
| preroll and stream-override handling | `applyMainItemStreamOverrides`, `hasMainItemStreamOverrides` | diverged |

Replacing the class wholesale would silently delete offline playback, the subtitle preference
algorithm and the queue resume behaviour. Those work today and a user would notice within one session.
This is precisely the failure mode I have been flagging in other people's work all through this port,
and I am not going to do it to you on the strength of my own mismeasurement.

### The closure, for the record

8 top-level declarations, 4,785 lines: `DetailActionButtons` (66), `DetailActionButtonsState` (4,022),
`_DetailActionButton` (45), `_DetailActionButtonState` (542), plus four small NEW helpers —
`_deleteFailureMessage` (16), `_deleteItemInBackground` (30), `_seerrRequestButton` (39),
`_seerrCancelButton` (25). The last two are top-level functions, not members; my first read put them
inside `_EpisodeProgressBar` because `owner()` walked back to the nearest `^class`.

`_DetailActionButtonState` is 542 upstream vs 251 in Voltix, and its three Voltix-only hunks are neon
theme rendering — a fork feature upstream does not have.

### Not proceeding until you choose

The scope question has changed and the earlier answer was based on a wrong number. Options are in the
question that follows this note.

## Tranche 22 — surgical modern-row port (the option you chose)

The four parameters were declared and never read. They read now, and every fork behaviour survives.

### What changed

| Site | Change |
|---|---|
| `_calculateMaxVisibleButtons` | honours `maxVisibleButtonsOverride`; TV cap 7 -> 11 in modern style; compact mobile tile maths (66 wide, 4 spacing, 40 padding) instead of the flat 80/8/64 |
| row build | `compact` includes `modernStyle && _isCompact`; `needsOverflow` also fires when a caller caps the row explicitly |
| both `Wrap` sites | `Align` with `centerLeft` in modern style vs `center`, `WrapAlignment.start` vs `center`, plus `crossAxisAlignment` |
| 3 arrow-right sites | `widget.onArrowRightAtEnd ?? () {}` — end of primary row, end of overflow row, and the More button |
| `_DetailActionButtonState` | `_buildModernChild` (270 lines) added, plus the `modern` flag read off the enclosing `DetailActionButtons` and the `child: modern ? … : …` branch. Voltix's own rendering, neon included, is the else |

`maxVisibleButtonsOverride` and `fullWidthPrimary` are now at **full parity** (4/4 and 3/3).

### The focus trap is closed

`onArrowRightAtEnd` was the one that mattered beyond cosmetics: it is how focus leaves the action row
on TV. All three escape points are wired, so the modern layout will not strand a remote user on the
button row.

### Confirmed still present, having been the reason not to replace

`_checkOffline` / `_offlineRow` / `_offlineQueue`, `_isSdhSubtitleStream`, `_isExternalSubtitleStream`,
the queue resume block, `neonAccentColor` rendering, `_openAudioSelector`,
`applyMainItemStreamOverrides`. All eight verified in place after the edit.

### Two documented remainders

**1. The two-column series branch.** `modernStyle` is 11/17 and `onArrowRightAtEnd` 5/7. The gap is
upstream's `if (widget.modernStyle) { … }` block (~96 lines) that gives series an inline-Play
two-column row on TV and desktop. Its `else` half is ported; without the `if` half, series in modern
style get the ordinary left-aligned wrap. Cosmetic, not broken.

**2. The five seerr buttons still render nothing.** Bigger than adding five map entries — upstream's
version needs a `shows()` predicate, a `seerr` local, an `onWatchlist` local, a `cancelByButton` map
and a restructured `primaryAction` slot (so Request takes the primary position for a title you do not
have, keeping Play's focus node). None of those exist in Voltix's build method, and `l10n.onWatchlist`
is missing. The three dialogs they open — report issue, manage requests, cancel request — and
`seerrPendingRequests` all landed in Tranche 16, so the pieces below it are ready.

That is the next tranche, and it is the one that clears the transient state from Tranche 21 where the
five switches appear in settings but reorder nothing.

Backup at `.bak-modernrow`.

## Tranche 23 — the five seerr buttons now render

This clears the transient state from Tranche 21, where the switches existed in settings but reordered
buttons that were never built.

### A latent error from Tranche 22, caught before analyze

`_buildModernChild` reads `widget.isPrimary`, and **Voltix's `_DetailActionButton` had no such field.**
Tranche 22 would have failed to compile. Added it, and — more easily missed — added it to
`_copyActionButton`, which every button passes through when the focus wiring rebuilds it. Without that
line the primary pill would have compiled fine and then silently lost its primary styling the moment
the row normalised its arrows.

### Ported

- top-level `_seerrRequestButton` (39) and `_seerrCancelButton` (25), verbatim
- five `byButton` entries: request, request 4K, watchlist (label and icon flip on `onUserWatchlist`),
  report issue (gated on `canReportIssue`), manage requests (gated on `canManageRequests` **and** a
  non-empty pending list)
- `cancelByButton`, a second map keyed on the same slots — so moving or hiding `seerrRequest` in the
  layout editor carries its cancel button with it rather than leaving it stranded
- the `primaryAction` slot: for a title not in the library, Request leads the row and **keeps
  `_tvPlayFocusNode`**, so everything that reaches for the play anchor still finds something. Falls
  back to the 4K request for a viewer only permitted that, then to Cancel when there is nothing left
  to ask for — and removes that cancel from the row so the same button is not offered twice.
  `byButton.removeWhere` then drops everything that means nothing without a library file.
- `allButtons` now spreads both maps per slot
- 6 imports, l10n `onWatchlist`

Voltix's `showsDetailButton` stands in for upstream's `shows`, and `PlatformDetection.isTV` for its
`autofocusPlay` local.

### Verified

All 15 symbols the new code needs are declared, no l10n key missing, no unresolved or duplicate
imports, brackets balanced, and `viewModel` / `_tvPlayFocusNode` / `buttonPrefs` / `showsDetailButton`
all confirmed in scope inside `DetailActionButtonsState`.

### Still outstanding on the modern screen

1. `modernStyle` 11/17 — upstream's two-column inline-Play branch for series on TV and desktop (~96
   lines). Cosmetic.
2. The `DetailScreenStyle.modern` branch is still not wired, so the six modern files remain
   unreferenced. That is the last step and it is now the only thing between here and the modern screen
   being reachable.

## Tranche 24 — the modern detail screen is now reachable

The `DetailScreenStyle.modern` branch is wired. The six files that had been sitting in `lib/`
unreferenced since the other party copied them in are now actually used.

### Three impedance mismatches, each fixed rather than papered over

**1. `backdropUrl` type.** `ModernDetailContent` wants a `ValueListenable<String?>`; Voltix keeps a
plain `String? _backdropUrl` and rebuilds through `setState`. Upstream uses a `ValueNotifier`
throughout, but converting Voltix's would change how the *classic* screen gets its backdrop updates —
a regression risk for a screen that works. So there is now a `_backdropListenable` mirror, and **every
write goes through one `_setBackdropUrl` setter** so the two cannot drift. Four write sites routed
through it, and the notifier is disposed with the state.

**2. `onPlayFromChapter`.** `ModernDetailContent` takes `void Function(Duration)?`, and does
`widget.onPlayFromChapter ?? (_) {}` — so passing null makes chapter taps silently do nothing.
Voltix's `_playFromChapter` lived on `_DetailContentState`, out of the screen's reach (upstream keeps
it on the screen state). It reads no state at all — only its four arguments, two top-level helpers and
GetIt — so it is now a **top-level function**, callable from both paths, and the screen passes a real
callback.

**3. `onSelectedMediaSourceChanged`.** Voltix's classic version only calls `setState`. The modern
version also calls `_viewModel.load(mediaSourceId: id)`, which is the whole point of the parameter
threaded through `server_core` in Tranche 21.

### A hollow flag I nearly left in

`_showNavbar` was written by `onToggleNavbar` and **read by nothing**. The modern layout collapses the
navigation chrome when its hero owns the top of the screen; without the read, the flag would flip and
nothing would happen. `showNavigationChrome` now reads it, matching upstream. Caught by checking
whether each new flag is consumed, not just declared — the same check that found the thirteen hollow
view-model members in Tranche 20.

### Where the modern screen now stands

Reachable, and the pieces beneath it are real rather than stubbed: paging and the playlist index
(Tranche 20), Seerr-only mode and `mediaSourceId` (21), the modern action-row styling and the TV focus
escape (22), the five seerr buttons and the request-leads-the-row primary slot (23).

One cosmetic remainder: `modernStyle` is 11/17 — upstream's two-column inline-Play branch for series
on TV and desktop (~96 lines). Series get the ordinary left-aligned wrap instead.

Backup at `.bak-modernbranch`.

### Worth testing by hand when you next build

The modern style is the **default** (`detailScreenStyle` defaults to `DetailScreenStyle.modern`), so
this switches on for everyone rather than sitting behind a setting nobody has touched. Worth a look
at: a movie, a series, a box set, a playlist, and a Seerr-only title reached from a home row; plus
offline playback, subtitle auto-selection and episode queue resume, which Tranche 22 deliberately
preserved but which no structural check can exercise.

## Remaining gap — measured after Tranche 24

`lib/` files: upstream **697**, Voltix **605**, **136 absent** (was 161 when I last measured).

**Seerr and the modern detail screen are both at zero missing files.** Those were the two threads this
port has been pulling on since the panel refactor.

| Area | Files | Status |
|---|---:|---|
| Books / audiobooks / reader | 36 | absent entirely — the fork-direction decision |
| Misc utilities & widgets | 34 | independent one-by-one ports, no blockers |
| Games / emulator | 29 | blocked on the native libretro backend |
| Platform integrations | 13 | CarPlay, MPRIS, Android Auto / TV Channels, Watch Next, push + Firebase, Apple TV, Aether |
| Offline catalog | 8 | Voltix has downloads but no `lib/data/offline` layer |
| Live TV / EPG | 7 | Voltix has its own guide — divergence, not a gap |
| Downloads | 5 | `background_download_coordinator`, `core_download_service`, `legacy_download_engine`, `macos_download_dir`, `downloads_panel` |
| Focus / gamepad | 3 | gamepad channel, key synthesizer, navigation scope |
| Admin | 1 | `running_tasks_card` |

Non-file items, all re-measured rather than recalled:

- **enums:** only `PassthroughCodec` absent. Still needs your decision — Voltix has a `truehd` member
  upstream lacks, so a naive port loses Atmos handling.
- **preferences:** upstream 306, Voltix 328 (the fork has more). Absent: `seerrBlockNsfw` (Voltix
  calls it `jellyseerrBlockNsfw` — a migration, not a rename) and `useNativeEmulator` (games).
- **l10n:** upstream 3,067 keys, Voltix 2,529. The 578 difference belongs to the unported features
  above; it is not separate work.
- **settings screens reachable:** upstream pushes 49, Voltix 51. The three upstream pushes Voltix
  lacks are `DownloadSettingsScreen` (dead in Voltix by design — the fork pushes its own
  `_OfflineDownloadsScreen` from that slot) and the two games screens.
- **modern action row:** `modernStyle` 11/17, `onArrowRightAtEnd` 5/7 — the two-column inline-Play
  branch for series on TV and desktop. Cosmetic.
- **23 default-value drifts** and `adaptiveListSection` on 6 header-interleaved screens — still
  decisions and hand work respectively.

### Unactioned since the first turn of this port

The **plaintext passwords in the backend server logs**. Rotate the exposed credentials and redact
`password`, `Pw` and `token` in the `[HTTP] Body:` logger. Not a port task, and the longest-open item
here by a wide margin.

## Porting halted — the upstream reference is gone

`~/mnt/Moonfin-Core-2.4.0/` is **empty** — the directory exists and contains nothing but `.` and `..`
(its own mtime is Aug 24 20:39, so something changed it recently). The other three mounts are fine.

Every remaining task needs to read upstream's source, so nothing further can be ported until that
folder is readable again. The likely causes, in order:

1. **OneDrive Files On-Demand dehydrated it.** The folder lives under
   `C:\Users\...\OneDrive - TLC - Think Logic Consulting (1)\Desktop\Moonfin-Core-2.4.0`, and a
   dehydrated cloud-only folder can present as empty to a process that is not the OneDrive client.
   Opening it in Explorer and choosing "Always keep on this device" would fix it.
2. The folder was moved, renamed or deleted.
3. The Cowork folder connection to it was dropped.

### Voltix itself is untouched and complete

- `lib/`: 605 Dart files; `packages/`: 155
- every file this session produced is present and the right size — the modern detail content (5,064
  lines), `tmdb_item_ref.dart`, the view model at 1,388 lines, the external lists screen at 2,692,
  the Seerr models at 172
- `PORT_PROGRESS.md` is 1,680 lines and intact
- nine `.bak-*` backups still in place

Nothing was lost. This is a read-side outage on the reference copy only.

## Tranche 25 — misc utilities & widgets (33 files) + one live bug fix

**Gap-mapped 50 candidate files** (upstream `lib/*.dart` absent from Voltix, minus the
books/games/offline/livetv/downloads/admin categories already tracked). Ported 32 of them
plus one additive package file. Verified: bracket balance with literals blanked (0 fail),
relative import resolution (0 missing), no leftover `moonfin_design` refs, no duplicate
top-level declarations, all 33 files non-empty.

### Ported
- `data/services/cast/receiver_device_profiles.dart`, `data/services/synced_fields.dart`
- `data/utils/{alphabet_bucket,media_deduplication_utils,next_up_cutoff}.dart`
- `playback/{auto_bitrate_service,sleep_timer_controller}.dart`
- `ui/navigation/deep_link_navigator.dart`
- `ui/screens/playback/appletv_playback_prompt_controller.dart`
- `ui/theme/oled_mode_tuning.dart`
- `ui/widgets/playback/{trickplay_tile_image,audio_quality_badge}.dart`
- `ui/widgets/settings/settings_section_header.dart`
- `ui/widgets/mediabar/{media_bar_status_focus,media_bar_title}.dart`
- `ui/widgets/{sliding_pill_tabs,status_banner_pill,app_update_banner,local_search_field}.dart`
- `ui/widgets/web_local_trailer{,_io,_web}.dart`
- `util/{audio_track_logic,subtitle_track_logic,image_mime,insecure_certificates,
  parental_rating_severity,season_queue_context,webview_environment}.dart`
- `util/{http_overrides_stub,http_overrides_io}.dart`
- `util/focus/row_focus_coordinator.dart`
- `packages/playback_core/lib/src/player_backend.dart` — replaced wholesale; the upstream
  diff is **purely additive** (no removals), adding `EmbeddedCaptionTrack` plus five
  defaulted `PlayerBackend` members (`supportsDirectPlayAudioSwitch`, `managesAudioFocus`,
  `demuxesEmbeddedSubtitles`, `embeddedCaptionTracks`, `setEmbeddedCaptionTrack`,
  `tracksChangedStream`). Because every addition carries a default, Voltix's existing
  backends still satisfy the interface unchanged.

### Deliberate divergence
`synced_fields.dart`: upstream syncs `SyncedField('seerrBlockNsfw', UserPreferences.seerrBlockNsfw, …)`.
Voltix stores this preference under its original key `jellyseerrBlockNsfw` (upstream migrated
the key in 2.4.0; Voltix has not). Ported as
`SyncedField('seerrBlockNsfw', UserPreferences.jellyseerrBlockNsfw, …)` — **wire name matches
upstream so server-side sync stays compatible, local storage key unchanged.** Comment in file.
This is a partial payment on the pending `seerrBlockNsfw` migration item; the full key
migration is still outstanding.

### Renames applied
`package:moonfin_design/moonfin_design.dart` → `package:voltix_design/voltix_design.dart` (8 files).
Verified first that every design symbol these widgets use exists in Voltix's design package —
Voltix's barrel lacks three upstream exports (`GlassAdaptiveScope`, `LiquidGlassWidgets`,
`oled_derivation.dart`, `ambient_background.dart`) but none of the ported widgets touch them.

### Excluded, with reasons (NOT "clear", despite passing the import/l10n gap map)

**Hollow without native code — Voltix has none of it (5 Kotlin files + manifest entries):**
- `playback/car_artwork.dart`, `data/services/watch_next_service.dart`,
  `playback/last_playback_session_store.dart`, `data/services/tv_channels_service.dart`,
  `background/watch_next_background.dart`
- Upstream backs these with `org/moonfin/androidtv/{MoonfinArtProvider,WatchNextPublisher,
  WatchNextWorker,PreviewChannelPublisher}.kt` + a `<provider>` manifest entry. Voltix's
  Android tree has **zero** matches for `watch_next`/`ArtProvider`. Porting the Dart alone
  would add an Android TV "Watch Next" row and Auto/CarPlay artwork that can never fire.
  → belongs to the platform-integration tranche, together with its Kotlin.

**Blocked on member gaps in files this tranche does not touch:**
- `playback/aether_backend.dart`, `playback/appletv_backend.dart` — both call
  `DeviceProfileBuilder` parameters Voltix lacks: `downmixToStereo`, `universalAudioDecode`,
  `transcodeHevcAllowed`, `hevcRequiresFmp4Hls`, `hlsAudioExcludesDts`; plus
  `known_defects.hasHardwareDolbyVisionDecoder` and `UserPreferences.downmixToStereo`.
- `playback/local_first_media_stream_resolver.dart` — needs `offline_stream_resolver`'s
  `isTranscoded` / `mediaSourceId` (absent in Voltix's version).
- `playback/{server_transcode_capabilities,local_aware_player_service}.dart` and
  `ui/widgets/aether_video_view.dart` — individually clean, but dead code without the
  backends above. Held with their cluster.
- **Aether native IS present in Voltix** (`ios/Runner/Playback/AetherVideoPlatformView.swift`
  is byte-identical to upstream's, and the `moonfin/ios_aether_*` channels come from the
  external `AetherEngine` SwiftPM package both repos pin). So the Aether cluster is
  unblocked *once the device-profile parity work lands* — it is not a native gap.

**Blocked on missing pub dependencies:** `push_messaging_service.dart`, `firebase_options.dart`
(firebase_core, firebase_messaging); `mpris_service.dart` (dbus); `util/focus/siri_remote_glide.dart`
(flutter_tvos + `gamepad_key_synthesizer.dart`).

**Blocked on books:** `playback/media_browse_service.dart` → `audiobook_resume_service.dart`,
plus 3 l10n keys (`carServerUnreachable`, `carSignInPrompt`, `shuffleAllMusic`).
`data/services/carplay_service.dart` depends on it in turn.

**Blocked on l10n:** `ui/widgets/identify_dialog.dart` — 12 `admin*` keys.
`data/services/tv_channels_service.dart` — `recentlyReleasedLibraryName`.

### Channel-naming audit (new finding)
Voltix's platform-channel naming is **mixed** and this is load-bearing, not cosmetic:
- Renamed to the fork: `com.voltix.app/*`, `com.voltix/*`, `voltix/hdr_display`,
  `voltix/media3_video_*`, `voltix/native_video_$viewId`, `voltix/external_player`
- **Still `moonfin/*` on both sides (correct — do not rename):** `moonfin/appletv_*`,
  `moonfin/sf_symbols`, `moonfin/aether_video*`, `moonfin/external_player` (Dart only, see below)

### Bug fixed: external player broken on Android
`lib/playback/external_player_service.dart:137` declared
`MethodChannel('moonfin/external_player')`, but Voltix's own
`android/app/src/main/kotlin/com/voltix/app/MainActivity.kt:113` registers
`"voltix/external_player"`. The fork renamed the Kotlin constant and missed the Dart side, so
**every external-player launch on Android has been hitting an unregistered channel.** No other
platform registers this channel. Changed the Dart constant to `voltix/external_player`.
This is a pre-existing fork defect, not something this port introduced.

### Also noted (not actioned)
`packages/playback_core/lib/` is missing two upstream src files still exported by upstream's
barrel: `track_ordinal_mapper.dart` and `transcode_reasons.dart`. Voltix's barrel does not
export them, so nothing is broken today — but they are a packages-level gap outside the
`lib/` diff this port has been tracking.

## Tranche 26 — device-profile parity (unblocks the Aether/AppleTV cluster)

### `known_defects.dart` — replaced wholesale
Diff is fully additive (verified: the only `-` lines are three set entries that return with
comments). Adds `AFTMM` + `BRAVIA 4K VH22` to `modelsWithDoViHdr10PlusBug`, and two defaulted
params (`hasHardwareDolbyVisionDecoder`, `hasDoviCompat`) to
`shouldAllowDolbyVisionProfile7ElDirectPlay`. Existing Voltix callers compile unchanged.

### `device_profile_builder.dart` — surgical additive merge, NOT a replace
Upstream's version differs by 250 added / **186 removed** lines. The removed lines are real
fork work, so a wholesale replace was rejected. Voltix owns an audio architecture upstream
2.4.0 does not have:
`AudioOutputMode`, `eac3JocPassthroughEnabled`, `dtsHdPassthroughEnabled`,
`dtsXPassthroughEnabled`, `trueHdAtmosPassthroughEnabled`, the web-capabilities path
(`_buildWebTranscodingProfiles` / `_buildWebDirectPlayProfiles` / `_buildWebCodecSets`), and
`AudioFallbackCodec.truehd`. **All of it is intact** (verified by occurrence count post-merge).

Added upstream's five knobs additively, each defaulting to the fork's existing behaviour:
- `downmixToStereo = false` → folded into the existing `forceStereo` expression.
- `universalAudioDecode = false` → when true, the advertised codec list is never narrowed;
  `forceStereo` still shapes the transcode fallback, matching upstream's documented intent.
- `bool? transcodeHevcAllowed` — **deliberately nullable, diverging from upstream's
  `= false`.** Upstream gates HEVC in the HLS offer behind a server probe; defaulting to
  `false` here would have silently dropped HEVC for every existing Voltix caller. `null`
  means "the fork's original rule: offer HEVC whenever the device supports it".
- `hevcRequiresFmp4Hls = false` → drops HEVC from the TS offer and lists fMP4 first.
- `hlsAudioExcludesDts = false` → new `_excludeDtsCodecs()` helper filters DTS from both HLS
  audio offers; returns the list unchanged when false.

**Behaviour-neutrality is provable by construction**, not just by test: with every default in
place `forceStereo` gains `|| false`; `_excludeDtsCodecs(x, false)` returns `x`;
`offerHevcTranscode` reduces to `effectiveSupportsHevc`; `tsVideoCodecs` reduces to
`hlsVideoCodecs`; and the profile list collapses to `[ts, fmp4, audio]` — the original order.
No existing call site changes. Only backends passing these explicitly opt in.

Verified: bracket balance (173/173, 405/405, 72/72), every new parameter read (no orphans —
the "written but never read" failure that bit `_showNavbar`), all fork params still present.
Backup at `device_profile_builder.dart.bak-dpb`.

### `UserPreferences.downmixToStereo` — deliberately NOT added
Upstream 2.4.0 replaced the fork's `audioOutputMode` enum with a boolean `downmixToStereo`
preference. Adding it would create two sources of truth that can silently disagree. When
`aether_backend.dart` lands, its one line becomes
`downmixToStereo: _prefs.get(UserPreferences.audioOutputMode) == AudioOutputMode.forceStereo`.

### Cluster status after this tranche
`aether_backend.dart` / `appletv_backend.dart` no longer have ANY missing member or
preference. Confirmed `dolbyVisionProfile7DirectPlayBehavior` does exist in Voltix
(user_preferences.dart:1528) — an earlier "missing" report was regex truncation.

### BLOCKER FOUND — AppleTV backend is not a new file
Voltix already has `lib/playback/appletv_mpv_backend.dart` (701 lines), which binds the same
`moonfin/appletv_video_control` / `_events` channels as upstream's `appletv_backend.dart`
(809 lines). **Adding upstream's file would register two backends on one channel.** This must
be a surgical diff against `appletv_mpv_backend.dart`, not a new file. Not attempted here.

### DECISION REQUIRED — AetherEngine on Apple
Upstream 2.4.0 moves iOS/macOS playback *entirely* off media_kit onto AetherEngine:
`main.dart` skips media_kit init on Apple and calls `_detectAndSetAetherCapabilities()` over
`moonfin/ios_aether_control`; `playback_module.dart` registers `AetherBackend` and returns it
from backend selection. Voltix's native side is **already fully in place** —
`AetherVideoPlatformView.swift` is byte-identical to upstream's and the AetherEngine SwiftPM
package is referenced in both `ios/` and `macos/` project files — but the Dart side still runs
the mpv/media_kit path. The fork appears to have pulled the native half and stopped.
Adopting this replaces Apple playback wholesale. Put to the user rather than assumed.

## Tranche 27 — AetherEngine adopted on iOS/macOS (user-approved) + login bug fix

### Login: "Connection failed. Please check your internet." was misdiagnosing itself
`directLogin` converts **every** `DioException` — connect timeouts, DNS faults, TLS errors —
into a `VoltixApiException`, and `voltix_login_screen.dart` catches that separately and shows
its message. So the "check your internet" string, which lives only in the bare `catch (e)`
fallback, **could never have been produced by a network failure.** It fired only when
something threw *after* the request came back.

Cause: `VoltixLoginResult.fromJson` read every field with a hard cast —
`json['sessionToken'] as String`, `json['user'] as Map<String, dynamic>`,
`json['servers'] as List`. Any null or reshaped field raised a `TypeError`, which is not a
`DioException`, so it escaped `directLogin` uncaught. `VoltixSessionResult.fromJson`
immediately below it has always been null-tolerant — login was the un-hardened one.

Fixed:
- `VoltixLoginResult.fromJson` now validates and raises a `VoltixApiException` naming what was
  missing ("The server did not return a session token", "No server is assigned to this account
  yet"), listing the fields that *were* present. Nested maps go through
  `Map<String, dynamic>.from(...)`, which also survives a `Map<dynamic, dynamic>` payload.
- Both `VoltixLoginResult.fromJson(json as Map<String, dynamic>)` call sites (directLogin:105
  and loginByMac:229 — there were **two**, not one) now guard the cast.
- The catch-all logs the real exception and stack trace via `_logger.e` and reports
  `'Sign-in failed: $e'` instead of blaming the network.
Backups: `voltix_api_service.dart.bak-login`, `voltix_login_screen.dart.bak-login`.

### AetherEngine on Apple — approved and wired
Confirmed first that this is what the fork's own native code already expects:
`ios/Runner/Playback/IosPiPController.swift` is documented "Picture-in-Picture for the
AetherEngine backend", imports `AetherEngine`, binds `AetherPlayerWrapper` and drives
`AVPictureInPictureController` itself. **iOS PiP could not have been working while iOS ran on
media_kit**, so dropping the `onNativeHandleReady: pipService.initializeIos` hook on iOS is not
a regression — it repairs a mismatch.

Ported: `playback/aether_backend.dart` (521), `ui/widgets/aether_video_view.dart` (66),
`playback/server_transcode_capabilities.dart` (40).

Wired (not left hollow):
- `main.dart` — media_kit init now also skipped on iOS/macOS; added
  `_detectAndSetAetherCapabilities()` over `moonfin/ios_aether_control` with upstream's
  iOS 16 / macOS 14 baseline fallback, called for iOS/macOS.
- `di/modules/playback_module.dart` — `AetherBackend` declared, constructed and registered on
  iOS/macOS; added to `initialBackend` selection and to runtime backend selection.
- `ui/screens/playback/video_player_screen.dart` — Aether branch at the top of
  `_buildVideoSurface()`.
- `ui/screens/livetv/live_tv_player_screen.dart` and
  `ui/widgets/live_tv/live_tv_mini_player.dart` — the other two surfaces upstream renders
  `AetherVideoView` in. **Without these, iOS/macOS would have played audio with no picture in
  Live TV** — the exact hollow outcome this port keeps guarding against.

Fork divergence in `aether_backend.dart`: upstream reads a dedicated
`UserPreferences.downmixToStereo`. Voltix keeps its `AudioOutputMode` enum, so the line became
`downmixToStereo: _prefs.get(UserPreferences.audioOutputMode) == AudioOutputMode.forceStereo`.
No new preference was added — two sources of truth would silently disagree.

Verified across all 8 touched files: bracket balance with literals blanked, relative import
resolution, no duplicate imports, `AudioOutputMode`/`PlatformDetection` in scope.
Backups: `*.bak-aether` on main.dart, playback_module.dart, video_player_screen.dart,
live_tv_player_screen.dart, live_tv_mini_player.dart.

### Still open in this area
`appletv_mpv_backend.dart` (701) vs upstream `appletv_backend.dart` (809) remains a surgical
diff, NOT a new file — both bind `moonfin/appletv_video_control`. Untouched.

## Analyze run 11 — 13 errors, 8 warnings. All fixed. Root cause was my own dismissal.

**The important lesson, recorded because it repeated:** my member-compat check in Tranche 25
*did* flag `sortName` and `codec` on `AggregatedItem`. I dismissed both by eye as generic-name
noise. They were real. The check was right and I overrode it. Every structural check in this
port has held; the failures have all come from me narrowing or second-guessing them.

### 1. `AggregatedItem` was missing 7 upstream getters
`alphabet_bucket.dart` needed `sortName`; `audio_quality_badge.dart` needed `audioContainer`,
`audioBitDepth`, `audioSampleRateHz`, `audioBitRate`, `isLosslessAudio`. Added all of these
plus `bannerImageTag` (same gap, no current caller), and the `_losslessCodecs` set — the only
supporting member Voltix lacked. `_defaultAudioStream`, `_toInt`, `audioCodec`, `mediaSources`
already existed. Backup: `aggregated_item.dart.bak-audiogetters`.

### 2. `AppleTvMpvBackend` broke on the new `PlayerBackend` members
`AppleTvMpvBackend` and `AetherBackend` use `implements PlayerBackend`; every other backend
uses `extends`. With `implements`, the base class's defaults do not apply, so the six members
`playback_core` gained in 2.4.0 had to be stated explicitly. They were given **the same values
the base class documents as "this engine doesn't decode them"** — not invented stubs.

Recorded in the file itself: upstream's `appletv_backend.dart` implements embedded captions
for real, feeding `EmbeddedCaptionTrack.listFromWire` from the native event stream so
AVFoundation's CEA-608 tracks reach the track menu. Until the outstanding
`appletv_mpv_backend` surgical diff lands, Apple TV offers no embedded caption tracks — which
is exactly what these values say. Backup: `appletv_mpv_backend.dart.bak-embedded`.

### 3. `item_detail_screen.dart` — `AdaptiveIcon` and `iconBuilder`
Both from the Tranche 22 `_buildModernChild` port.
- `AdaptiveIcon` **already exists** in Voltix (`ui/widgets/adaptive/sf_symbol.dart:48`) — the
  file simply never imported it. Signature confirmed compatible:
  `const AdaptiveIcon(this.icon, {super.key, this.size, this.color})`.
- `iconBuilder` was a genuine field gap. Added to `_DetailActionButton` as an optional
  `Widget Function(double, Color)?`. **`icon` deliberately stays non-nullable** (upstream makes
  it nullable) so no existing Voltix call site changes; the icon is simply not drawn when a
  builder is supplied. The four `widget.icon ?? Icons.play_arrow` / `widget.icon!` sites — the
  8 warnings — were upstream-shaped guards that are dead against a non-nullable field, and were
  reduced to `widget.icon`.
- **Threaded `iconBuilder` through `_copyActionButton`.** Without it the modern pill would
  silently lose its custom glyph on rebuild — the identical failure `isPrimary` had in
  Tranche 22. Backup: `item_detail_screen.dart.bak-iconbuilder`.

Re-ran the member check afterwards against real declarations rather than name plausibility:
0 problems across all 36 files from Tranches 25–27.

## Analyze run 12 — CLEAN (0 errors, 0 warnings, 0 infos)

First fully clean run covering Tranches 25, 26 and 27 (misc utilities, device-profile parity,
AetherEngine adoption on iOS/macOS, and the login-error fix). Static analysis is now a green
baseline again; the outstanding gate is a device test on Apple, since Tranche 27 replaced
iOS/macOS playback wholesale.

## Tranche 28 — AppleTvMpvBackend → AppleTvBackend: the tvOS cluster adopted wholesale

### Why this was bigger than "a surgical diff" as originally scoped
Flagged in Tranche 26 as needing "a surgical diff against appletv_mpv_backend.dart, not a new
file." On investigation it turned into a 4-file, ~2000-line cluster: the backend itself plus
two host screens plus a feeder, because upstream 2.4.0 refactored inline next-up/skip-segment/
still-watching logic in the host screens into the shared `AppleTvPlaybackPromptController` —
the same controller ported (but left unwired) in Tranche 25.

### Confirmed before touching anything: Voltix's tvOS native side is ALREADY AetherEngine
`tvos/Runner/Playback/AppleTvVideoChannel.swift` is **byte-identical** to upstream's
(`diff -q` returned nothing) — `import AetherEngine`, `AetherPlayerWrapper` throughout. So
`AppleTvMpvBackend`'s name and its mpv-shaped device-profile construction were stale even
before this port started; the fork's own native tvOS binary was never running mpv. This
explains upstream's `rowEntry('Player', 'AetherEngine')` replacing the fork's
`rowEntry('Player', 'MPVKit (libmpv)')` — the label was simply wrong.

### Verification before adopting (same rigor as the DPB merge, different conclusion)
Compared method/getter surfaces between fork and upstream across all 4 files:
- `appletv_backend.dart`: only ONE fork-only member (`_nativeDvDecodeEnabled`, a private
  helper superseded by upstream's `hasHardwareDolbyVisionDecoder` approach — the same P7
  handling merged into `device_profile_builder.dart` in Tranche 26).
- `appletv_player_host_screen.dart`: 4 fork-only methods — `_prettyPlayMethod`,
  `_segmentLabel`, `_resolveSegmentsAsync`, `_nextUpThresholdMs` — all confirmed superseded
  (formatting moved to the new shared `util/play_method_label.dart`; segment/next-up/
  still-watching state moved into `AppleTvPlaybackPromptController`).
- `appletv_livetv_player_host_screen.dart`: 1 fork-only method, same `_prettyPlayMethod`.
- `appletv_audio_now_playing_feeder.dart`: diff was a **pure rename**, zero behavior change.
- SyncPlay integration is present and unchanged in both versions — not a fork feature at risk.

Then gap-mapped every import target of the 4 files against Voltix (0 absent) and ran the
member-existence check against the 14 files that differ. It surfaced 20-odd hits; every one
was verified a false positive from the checker matching local variables/keywords (`logoUrl`,
`prefs`, `segments`, `chunk`, `embedded`, `values`, `switch`, `while` — not real member
accesses). Two closer calls were checked directly: `MediaSegmentService.segments` getter exists
(`media_segment_service.dart:17`), and l10n key `embedded` exists
(`app_localizations.dart:2591`). Zero real gaps.

### Applied
- `lib/playback/appletv_mpv_backend.dart` → moved to `_to_delete/lib/playback/` (device_bash
  cannot delete on a mounted folder — see note below) — replaced by
  `lib/playback/appletv_backend.dart`, upstream's file, class renamed to match.
- `lib/ui/screens/playback/appletv_player_host_screen.dart` and
  `appletv_livetv_player_host_screen.dart` — full wholesale replace with upstream's versions.
- `lib/playback/appletv_audio_now_playing_feeder.dart` — mechanical rename only.
- `lib/main.dart` and `lib/di/modules/playback_module.dart` — `AppleTvMpvBackend` →
  `AppleTvBackend` throughout (declaration, construction, registration, both backend-selection
  branches).
- `package:moonfin_design` → `package:voltix_design` in both host screens.

**Result: the Tranche 25 `AppleTvPlaybackPromptController` port is no longer hollow.**
`appletv_player_host_screen.dart` now has a private `_HostPromptCommands` adapter
(`implements AppleTvPromptCommands`) constructing the controller and driving
next-up/skip-segment/still-watching through it — exactly the pattern upstream also uses for
the non-AppleTV video player screen tranche 25 already wired.

Verified: bracket balance across all 6 touched files, all imports resolve, exactly one
`AppleTvBackend` declaration in the tree (no duplicate class), zero remaining
`AppleTvMpvBackend`/`appletv_mpv_backend` references anywhere.

**User note:** `device_bash` cannot delete files on a connected folder. The superseded
`appletv_mpv_backend.dart` was moved to `_to_delete/lib/playback/appletv_mpv_backend.dart`
inside your Voltix folder — delete that `_to_delete` folder yourself when convenient. Backups
of every replaced/edited file are alongside the originals as `*.bak-applereplace` /
`*.bak-applereplace2`.

## Analyze run 13 — 1 error, fixed

`appletv_player_host_screen.dart:449` used `StreamResolutionResult.deliveredBitrate`
(upstream's stats-panel bitrate display, adopted with the rest of the file in Tranche 28), but
Voltix's `packages/playback_core/lib/src/stream_resolution_result.dart` didn't have it yet —
a gap in Tranche 28's cross-package coverage (the earlier `apple_gap.py` sweep only walked
`lib/`, not `packages/`).

Diffed the two versions: purely additive — two new optional fields with defaults
(`selectedSubtitleStreamIndex`, `isLocalMedia`) and the new `deliveredBitrate` getter, which
reads the delivered video+audio bitrate off the transcode URL's query params (falling back to
`maxstreamingbitrate`) rather than reporting the source bitrate during a transcode. Nothing
removed; all existing constructor call sites use named parameters, so the two new optional
fields cannot break them. Applied the file wholesale.

## Tranche 29 — server user-agent + shared probe (fixes a real connectivity bug)

Continued past the AppleTV cluster into a fresh full gap map across `lib/` AND `packages/`
(the sweep that Tranche 28's `apple_gap.py` missed by only walking `lib/`). Bucketed the 171
remaining missing files: books/reader-related (kindle_unpack, flutter_inappwebview_windows —
blocked on the open books decision), games/emulator (blocked on native libretro, unchanged),
and a small `packages/server_core/lib/src/network/` pair worth doing now.

### `server_user_agent.dart` — real bug, not cosmetic
Every request Voltix makes to a Jellyfin/Emby server went out with Dart's raw default
`Dart/x.x (dart:io)` user agent. Upstream's comment states plainly: some reverse proxies and
WAFs reject that outright, so a server that IS reachable reads as unreachable — the connection
probe fails at the network level before any auth even happens. Ported the file (`serverUserAgent`
getter → `Mozilla/5.0 (compatible; Voltix/$_version)`, kept the fork's name in the string rather
than upstream's `Moonfin/$_version`) and wired it in three places:
- `packages/server_core/lib/src/network/configure_server_dio_io.dart` — `client.userAgent =
  serverUserAgent` on the HttpClient every server request goes through.
- `packages/server_core/lib/server_core.dart` — exported from the barrel.
- `lib/di/injection.dart` — `setServerUserAgentVersion(appVersion)` added to
  `configureDependencies()`, right after the existing `_resolveAppVersion()` call, matching
  upstream's placement.
The web Dio stub (`configure_server_dio_stub.dart`) needs no change — identical to upstream,
and a browser controls its own `User-Agent` regardless.

### `server_probe.dart` — deduplicated into `server_repository.dart`, not left hollow
Ported the shared `probeServerPublicInfo()` helper, but did NOT stop at just adding the file:
`lib/auth/repositories/server_repository.dart` had its own private `_probeServer`, and porting
the shared helper without wiring a consumer would have repeated the exact "declared but never
called" mistake this port keeps catching. Diffed the two implementations first:

**Real functional gap found, not just duplication** — Voltix's inline probe only tried
`/System/Info/Public`. The shared helper also tries `/emby/System/Info/Public`, so an Emby
server reachable only via that path behind a reverse proxy previously read as unreachable in
Voltix; it now doesn't.

Replaced Voltix's `_probeServer` body to call `probeServerPublicInfo(dio, baseUrl)` and adjusted
the one call site from destructuring a 3-tuple to reading `.info` / `.serverType` /
`.resolvedBaseUrl` off `ServerProbeResult`. One divergence preserved deliberately: the shared
helper's `_resolveBaseUrl` only strips the `/System/Info/Public` suffix, while Voltix's own
`normalizeServerBaseUrl` (kept, not replaced) also strips a trailing `/web` or
`/web/index.html` — so the call site now applies `normalizeServerBaseUrl` to the result
unconditionally (previously applied only when a redirect had fired; unconditional is a
no-op on an already-normalized URL, so this is not a behavior change, just a simplification).

**Left alone, deliberately:** `lib/auth/services/server_discovery_service_web.dart` has its own
`_probeServer` too, but it's a worker-pool LAN scanner (web-only, `dart:js_interop`, scans many
candidate IPs concurrently into `DiscoveredServer`) — a fundamentally different shape than the
single-URL helper, and web is a lower-traffic platform here. Not touched.

Verified: bracket balance (raw, unblanked count — 135/135, 39/39, 16/16 — the blanked-literal
checker threw a false-positive on this file, traced to a string-stripping regex quirk, confirmed
harmless by comparing raw parenthesis counts against the pre-edit backup, which showed the
identical checker artifact untouched by today's edit), import resolution, zero remaining
3-tuple destructuring call sites, `ServerProbeResult` used consistently.

## Tranche 30 — EPG cluster (new Live TV guide UI + a self-caught GetIt regression)

Fresh full gap map across `lib/` AND `packages/` (171 missing files, bucketed). Went after the
Live TV guide next: `lib/ui/screens/livetv/live_tv_guide_screen.dart` (962 diff lines of ~1690),
`lib/data/viewmodels/live_tv_guide_view_model.dart` (248 diff lines, 358→550), and 6 brand-new
files under a new `lib/ui/screens/livetv/epg/` directory (`epg_genre.dart` plus 5 widgets:
`epg_channel_cell`, `epg_filter_rail`, `epg_hero_preview`, `epg_now_next_card`,
`epg_program_cell`).

### Investigated first, applied nothing (out of scope / deliberately deferred)
- `packages/design` theme gaps (`eightbit_hero_theme_spec.dart`, `moonfin_theme_spec.dart`,
  `oled_derivation.dart`, `ambient_background.dart`, `isPixel` support) — would require touching
  9 additional files across the theming system for a cosmetic addition. Deferred as
  too invasive for what it buys.
- Reconfirmed Voltix's `theme_registry.dart` deliberately withholds the `glass` theme (documented
  GPU-freeze bug on Android TV/mid-range phones — `GlassBackdrop`'s always-animating controller
  + `GlassSurface`'s per-surface blur). **Not touched, not "fixed."**

### Diffed before applying
Class structure is unchanged (`_GuideGridView`, `_GuidePillButton`, `_GuideFocusableSurface`,
`_GuideProgramRow` present in both) — this is modularization plus feature-add, not a UI paradigm
shift. Method-surface diff found only 3 fork-only methods in the screen (`_buildFilterChips` →
superseded by `EpgFilterRail`; `_showChannelSchedule` → superseded by `EpgHeroPreview`;
`_scrollToCurrentTime`/`_hasScrolledToNow` → resolved below, not a loss) and 1 in the view model
(`_fetchPrograms` → folded into `_loadNextBatch`/`_loadProgramsBatch`).

Import gap-map: 0 absent, 10 differing deps, all checked at the member level. 4 were false
positives (`borders`/`cardBorder`/`chipBorder` already exist on `ThemeSpec`, unrelated name
match; `favorites`/`series` are `GuideFilter` enum values in the very file being replaced). 1 was
a real, small gap: `transparentPreview` missing on `live_tv_mini_player.dart`.

**Where `_scrollToCurrentTime` went — confirmed not a feature loss.** The old fork loaded a
fixed-start guide window, then separately jumped the horizontal scroll to the current-time
column once data arrived. Upstream's `LiveTvGuideViewModel.load()` instead sets `_windowStart`
to `DateTime(guideDate.year, guideDate.month, guideDate.day, DateTime.now().hour)` — i.e. the
guide window itself now starts at the current hour on load, so the view already opens showing
"now" without a separate scroll step. Confirmed by reading `load()` directly
(`live_tv_guide_view_model.dart:335-350`). No port action needed — the old scroll methods are
correctly gone, not lost.

**Where `embedded`/`onChannelSelected`/`onClose` are used — a real, wired upstream feature,
NOT yet in Voltix, and NOT part of this tranche.** Traced every upstream call site
constructing `LiveTvGuideScreen`. `app_router.dart` and
`appletv_livetv_player_host_screen.dart` construct it the same way Voltix already does (no
`embedded`). But `live_tv_player_screen.dart` has a second, new call site —
`_buildGuideOverlay()` — that passes `embedded: true` to show the full guide as an in-player
overlay while a Live TV channel is playing (press-a-button-to-browse-and-switch-channel,
without leaving the player). That file grew from Voltix's 1386 lines to upstream's 2114 —
a 728-line diff, almost entirely unrelated to the guide cluster itself. This is a real gap, but
big enough and separate enough to deserve its own tranche rather than being folded in here
unverified. **Deferred to next tranche; flagging now so it isn't lost.**

### A self-caught regression from two tranches ago
While diffing `live_tv_mini_player.dart` for the `transparentPreview` field, found that upstream
replaced:
```dart
final MediaKitPlayerBackend? _fallbackMediaKitBackend =
    (PlatformDetection.isTizen || PlatformDetection.isAppleTV)
    ? null
    : GetIt.instance<MediaKitPlayerBackend>();
```
with:
```dart
final MediaKitPlayerBackend? _fallbackMediaKitBackend =
    GetIt.instance.isRegistered<MediaKitPlayerBackend>()
    ? GetIt.instance<MediaKitPlayerBackend>()
    : null;
```
That's upstream fixing the exact bug Tranche 27 introduced into Voltix: once `AetherEngine`
adoption stopped registering `MediaKitPlayerBackend` on iOS/macOS, this old Tizen/AppleTV-only
guard no longer covers iOS/macOS, so this line would throw a GetIt "unregistered type" error at
construction time on a real iOS or macOS device. Searched the whole tree for the pattern — it
was in **three** files, not just this one: `live_tv_player_screen.dart:50`,
`video_player_screen.dart:94`, `live_tv_mini_player.dart:53`. Fixed all three with the
`isRegistered` guard and a comment explaining why. Confirmed `playback_module.dart`'s runtime
`setBackendSelector` already early-returns for iOS/macOS before it would reach
`_getIt<MediaKitPlayerBackend>()`, so those occurrences are unaffected and correct as-is.

### Applied
- `lib/ui/screens/livetv/live_tv_guide_screen.dart` — wholesale replace, `moonfin_design` →
  `voltix_design`. Backup `.bak-epg`.
- `lib/data/viewmodels/live_tv_guide_view_model.dart` — wholesale replace. Backup `.bak-epg`.
- `lib/ui/screens/livetv/epg/epg_genre.dart` and `epg/widgets/*.dart` (5 files) — new,
  copied verbatim with the `voltix_design` package rename.
- `lib/ui/widgets/live_tv/live_tv_mini_player.dart` — NOT wholesale replaced (already diverged
  with the Aether/GetIt work). Surgically added the `transparentPreview` field + constructor
  param + doc comment, a `Colors.transparent` override in the frame's `AnimatedContainer`
  decoration, and a `SizedBox.expand()` short-circuit at the top of `_buildPreviewSurface()`.
  This file now carries three backup suffixes from this session: `.bak-aether`,
  `.bak-mediakitguard`, `.bak-epg`.
- `lib/ui/screens/livetv/live_tv_player_screen.dart`,
  `lib/ui/screens/playback/video_player_screen.dart`,
  `lib/ui/widgets/live_tv/live_tv_mini_player.dart` — the `isRegistered<MediaKitPlayerBackend>()`
  guard fix described above. Backup `.bak-mediakitguard` on all three.

Verified: bracket balance and import resolution across all 9 touched/new files — all pass.
Constructor compatibility checked for `LiveTvGuideScreen`'s new optional params (`embedded`,
`onChannelSelected`, `onClose` all default `false`/`null`) against all current Voltix call
sites — all 3 external callers still compile unchanged since none of them pass those params yet
(consistent with the fact that upstream's own non-overlay callers don't either).

**Not yet done:** the in-player guide-overlay feature in `live_tv_player_screen.dart` (728-line
diff) — next tranche. `flutter analyze` has not been re-run since these changes; please run it
again when convenient.

## Tranche 31 — live_tv_player_screen.dart (in-player guide overlay + mobile controls)

Upstream grew from 1386 to 2114 lines (+728). The additions fall into 5 clusters:

**1. In-player guide overlay** (`_buildGuideOverlay`, `_closeGuideOverlay`,
`_onGuideChannelSelected`) — wires up the `embedded: true` `LiveTvGuideScreen` construction
deferred from Tranche 30. The guide now slides in-over-video while a channel plays; selecting
a channel in it calls `_onGuideChannelSelected` which switches streams without navigating away.

**2. Mobile gesture controls** (`_onVerticalDragStart/Update/End/Cancel`, `_initBrightness`,
`_syncBrightnessFromSystem`, `_setBrightness`, `_initSystemVolume`, `_setMobileSystemVolume`,
`_setMedia3VolumeBoostLevel`) — swipe-up/down on left/right half of the screen to
adjust brightness or volume. Uses `screen_brightness_platform_interface`,
`screen_brightness_android/ios`, `volume_controller` packages (all already in Voltix's pubspec
and lockfile from earlier tranches). Overlays: `_buildVolumeOverlay`, `_buildBrightnessOverlay`,
`_buildGestureIndicator`.

**3. Runtime track selectors** (`_showAudioSelector`, `_showSubtitleSelector`,
`_showBitrateSelector`, `_listenForPlayerTrackChanges`, `_onPlayerTracksChanged`,
`_streamLabel`) — audio/subtitle/bitrate pickers accessible from the overlay controls, using the
already-ported `TrackSelectorDialog` widget and `SubtitleTrackLogic` utility. `_showInfo`
now also calls `_listenForPlayerTrackChanges()` so tracks update live while the overlay is open.

**4. PiP support** (`_onPiPChanged`, `_onPiPAction`, `_onScreenLock`, `_pipChangedSub`,
`_pipActionSub`, `_pipScreenLockSub`) — wires the `PipService` (already ported in an earlier
tranche) to the player lifecycle. PiP events pause/resume the info overlay. App lifecycle
handling via `WidgetsBindingObserver` (mixin now added to the state class).

**5. UI structure refactor** (`_buildTopOverlay`, `_buildBottomOverlay`,
`_buildPlaybackControlsRow`, `_buildTimelineSection`, `_buildOverlayControlButton`,
`_buildVideoChild`, `_buildTizenVideoChild`, `_buildBufferingIndicator`, `_hideInfo`) — the
monolithic `build` method is broken into named sub-builders; `_hideInfo` separates the hide
path from `_toggleInfo`. The old `_showChannelPicker` modal (Voltix-only) is superseded by
the embedded guide overlay.

### Applied
Wholesale replace, `moonfin_design` → `voltix_design` and `moonfin_native_video` →
`voltix_native_video` (both package name AND barrel-file path). Backup `.bak-livetv31`.

All dependencies verified present: every relative import resolves, all six new
packages/utilities already in Voltix's pubspec and lockfile. Bracket balance: 261/261 braces,
1009/1009 parens. Zero moonfin refs remaining.

Note: the `MediaKitPlayerBackend` `isRegistered` guard introduced in Tranche 30's
regression-fix is already present in upstream's copy of this file with identical semantics —
wholesale replace preserves that fix.

---

## Tranche 33 — Playback cluster, services, UI widgets, DI wiring

### Files added

**`lib/app.dart`** (surgical merge):
- Added imports: `gamepad_navigation_scope.dart`, `siri_remote_glide.dart`
- `initState`: `SiriRemoteGlide.instance.attach()` added inside `isAppleTV` block after `TopShelfService().startDeepLinkListener`
- Widget tree: `InputModeTracker` wrapped with `GamepadNavigationScope`
- Backup: `.bak-gamepad`

**`lib/data/services/watch_next_service.dart`** (NEW):
- Copied from upstream with method channel rename: `org.moonfin.androidtv/watch_next` → `com.voltix/watch_next`

**`lib/background/watch_next_background.dart`** (NEW):
- Directory `lib/background/` created
- Copied from upstream with method channel rename: `org.moonfin.androidtv/watch_next` → `com.voltix/watch_next`
- Dependencies: `TvChannelsService` ✓, `CarArtwork` ✓, `HeadlessSessionBootstrap` ✓, `WatchNextService` ✓

**`lib/ui/screens/home/home_view_model.dart`** (surgical merge):
- Added imports: `tv_channels_service.dart`, `watch_next_service.dart`
- Added fields: `_tvChannels = TvChannelsService()`, `_watchNext = WatchNextService()`
- Added calls after `_topShelf.update(_rows)`: `_watchNext.update(_rows)`, `_tvChannels.update()`

**`lib/playback/last_playback_session_store.dart`** (NEW — verbatim, no moonfin refs)
**`lib/playback/local_aware_player_service.dart`** (NEW — verbatim, no moonfin refs)
**`lib/playback/local_first_media_stream_resolver.dart`** (NEW — verbatim, no moonfin refs)
**`lib/playback/mpris_service.dart`** (NEW — renames: `org.mpris.MediaPlayer2.moonfin` → `org.mpris.MediaPlayer2.voltix`, `org.moonfin.linux` → `com.voltix.linux`, `/org/moonfin/track/` → `/com/voltix/track/`)

**`lib/data/services/background_download_coordinator.dart`** (NEW — renames: `moonfinMedia` → `voltixMedia`, `moonfinMediaDownloads` → `voltixMediaDownloads`)
**`lib/data/services/legacy_download_engine.dart`** (NEW — verbatim, no moonfin refs)
**`lib/data/services/macos_download_dir.dart`** (NEW — method channel rename: `moonfin/macos_download_dir` → `com.voltix/macos_download_dir`)

**`lib/data/services/download_service.dart`** (WHOLESALE REPLACE):
- Upstream adds `BackgroundDownloadCoordinator` integration, `LegacyDownloadEngine` refactor, `background_downloader` package support, TLS retry logic, media group constants
- Voltix-only user-agent strings (`'Voltix/Flutter'`) superseded by `serverUserAgent` from `server_core`
- Backup: `.bak-ds33`

**`lib/ui/screens/downloads/downloads_panel.dart`** (NEW — moonfin_design → voltix_design)
**`lib/ui/widgets/identify_dialog.dart`** (NEW — moonfin_design → voltix_design)

**`pubspec.yaml`** (additions): `background_downloader: ^9.5.6`, `path: ^1.9.1`

### DI / wiring changes

**`lib/di/modules/server_module.dart`** (surgical merge):
- Added import: `background_download_coordinator.dart`
- Added registrations in `registerServerModule()`: `BackgroundDownloadCoordinator`, `SeerrNotificationService`

**`lib/di/modules/playback_module.dart`** (surgical merge):
- Added imports: `headless_session_bootstrap.dart`, `last_playback_session_store.dart`, `local_aware_player_service.dart`, `local_first_media_stream_resolver.dart`
- Added registrations in `registerPlaybackModule()`: `HeadlessSessionBootstrap`, `LastPlaybackSessionStore`
- `setActiveStreamResolver()`: resolver now wrapped with `LocalFirstMediaStreamResolver(inner: resolver, offline: _getIt<OfflineStreamResolver>())`; service wrapped with `LocalAwarePlayerService(service, _getIt<OfflineRepository>(), canReachServer: () => true)` — placed BEFORE the existing `MultiServerPlayerService` wrapping so the call chain is `Multi(LocalAware(Server))`

**`lib/main.dart`** (surgical merge):
- Added import: `playback/mpris_service.dart`
- Added `initMprisService(...)` call guarded by `PlatformDetection.isLinux`

### Verification / divergences

- **Method channels `moonfin/...`** in `theme_audio_player.dart`, `topshelf_service.dart`, `screensaver_controller.dart`, `sf_symbol.dart`, `aether_video_view.dart`, `app_exit.dart` — intentionally left unchanged. Voltix's native Swift/Kotlin code (tvos/Runner/, ios/Runner/) uses identical `moonfin/` strings. Both sides match; renaming either without the other would break the channel.
- **`media_browse_service.dart`** — BLOCKED: depends on `audiobook_resume_service.dart` (books/audiobooks cluster, pending user decision). Will port once that decision is made.
- **`push_messaging_service.dart`** — BLOCKED: requires Firebase (firebase_core, firebase_messaging, firebase_options.dart). Firebase is not in Voltix's pubspec. Needs user decision on whether Voltix wants Firebase push notifications; if yes, run `flutterfire configure` for Voltix's Firebase project first.
- **`carplay_service.dart`** — BLOCKED: depends on `media_browse_service.dart` (above).
- **Games cluster** (game_*, emulator_*, native_game_*, appletv_game_player.dart) — NEW cluster identified; needs user decision analogous to books/audiobooks.
- **`LocalAwarePlayerService.canReachServer`** — hardcoded to `() => true` (always reachable). Upstream uses `ConnectivityService.canReachServer` but `ConnectivityService` is not in Voltix. Result: local downloads always play from server if reachable. Revisit when/if `ConnectivityService` is ported.
- **Tranche 33 gap closure**: After filtering books, games, firebase, and carplay clusters, 0 non-blocked upstream files remain unported.


---

## Session — Books/Games/Firebase cluster completion

### Analyze fixes applied (session start — 10 issues → 0)

- **`connectivity_aware_media_server_client.dart`**: Added `homeScreenSectionsApi` forwarding getter
- **`stopTranscoding`**: Added no-op / delegate to `EmbyPlaySessionService`, `PlaySessionService` (jellyfin), `MultiServerPlayerService`, `NoOpPlayerService`
- **`HomeRowType.recentlyReleased`**: Already in switch (confirmed); error was pre-session ghost
- **`download_service.dart`**: Added curly braces at lines 558 and 2060
- **`emby_items_api.dart` / `jellyfin_items_api.dart`**: Added `@override` on `getItem`
- **`pubspec.yaml`**: Moved `gamepads_linux` from `dependencies` to `dependency_overrides`

### Books / Audiobooks cluster (COMPLETE)

36 new files copied from upstream into Voltix; 6 existing files compared:

**New files** (all `moonfin_design` → `voltix_design` applied):
- `lib/data/models/reader_settings.dart`
- `lib/data/services/audiobook_{bookmarks,notes,resume}_service.dart`
- `lib/data/services/reader_settings_store.dart`
- `lib/data/viewmodels/book_browse_view_model.dart`
- `lib/ui/screens/book/discover/` (4 screens)
- `lib/ui/screens/browse/book_browse_screen.dart`
- `lib/ui/screens/playback/audiobook_player_view.dart`
- `lib/ui/widgets/audiobook/` (11 widgets)
- `lib/ui/widgets/book/` (8 widgets + 2 discover widgets)
- `lib/ui/widgets/reader/` (3 widgets)

**Existing files updated**:
- `lib/data/services/book_document_service.dart` — WHOLESALE REPLACE: upstream adds `BookDocumentStyle`, `convertKindleToEpub()`, proper image inlining (`_inlineLocalImages`), `serverUserAgent` in HttpClient, `BookDocumentStyle` CSS generation
- Others (`bookshelf_detail`, `book_reader_service`, `bookshelf_glow`, `bookshelf_layout`) — identical or intentionally different (`book_reader_screen.dart` uses `webview_flutter`, upstream uses `flutter_inappwebview`; kept as-is)

**Packages**: `packages/kindle_unpack/` copied from upstream (pubspec.yaml already declared it)

**Unblocked by books**: `carplay_service.dart` and `media_browse_service.dart` (now copied)

### Games cluster (COMPLETE)

26 new files copied from upstream into Voltix:
- `lib/data/services/core_download_service.dart`
- `lib/data/viewmodels/game_system_browse_view_model.dart`
- `lib/playback/appletv_game_player.dart`, `native_game_player.dart`, `native_game_player_channel.dart`
- `lib/ui/screens/games/` (3 screens)
- `lib/ui/screens/playback/game_audio_owner.dart`, `game_emulator_screen.dart`, `native_game_player_screen.dart`
- `lib/ui/screens/settings/downloaded_games_screen.dart`, `emulator_cores_screen.dart`
- `lib/ui/widgets/game/` (5 widgets)
- `lib/util/game_{browse_filter,core_licenses,cores,cores_abi_io,cores_abi_stub,library,storage}.dart`

**Channel renames**: `moonfin/native_game_control` → `voltix/native_game_control`, `moonfin/native_game_events` → `voltix/native_game_events`, same for appletv variants; settings sentinel `moonfin-global` → `voltix-global`

**Note**: `game_emulator_screen.dart` legitimately uses `flutter_inappwebview` (both packages are in Voltix's pubspec). No changes needed.

### Firebase (COMPLETE — stub)

- `lib/data/services/push_messaging_service.dart` — copied from upstream, no upstream refs
- `lib/firebase_options.dart` — STUB created with `REPLACE_ME` placeholders. **ACTION REQUIRED**: run `flutterfire configure` with Voltix's Firebase project to regenerate this file with real credentials.

### Resolved non-issues

- **`PassthroughCodec.truehd`**: Not applicable to Voltix. Voltix uses string preference keys (`pref_passthrough_truehd`) directly; no enum needed.
- **`seerrBlockNsfw` migration**: Voltix consistently uses `jellyseerrBlockNsfw` throughout. No references to the renamed key. No migration needed at this time.

### Remaining

- **`firebase_options.dart`**: Needs real Firebase credentials (`flutterfire configure`)
- **`_to_delete/lib/playback/appletv_mpv_backend.dart`**: Delete manually from Windows Explorer
- **SECURITY CRITICAL (unactioned)**: Hardcoded `voltix-admin`/`admin` in `server/localAuth.ts:378` `seedVoltixAdmin()` — do NOT touch without explicit instruction
- **Run `flutter analyze`** to verify 0 errors after this session's changes
