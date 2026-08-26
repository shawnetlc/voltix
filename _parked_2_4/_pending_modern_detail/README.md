# Modern detail screen — ported, parked, not wired

The six `modern/` files are ported (package names rewritten, `ThemeRegistry.moonfinId`
-> `voltixId`) and all balance-check clean. They are parked **outside `lib/`** on purpose:
`flutter analyze` walks everything under `lib/`, so leaving them in place would fail the
build on ~14 undefined symbols.

## Why it is not wired

`modern_detail_content.dart` imports 14 symbols from `item_detail_screen.dart`:

    DetailActionButtons, DetailCastRow, DetailChaptersRow, DetailFeaturesRow,
    DetailEpisodeCard, DetailSimilarRow, DetailTrackList, ExpandableBiography,
    selectedMediaSourceForItem, PersonDates, FilmographyRow,
    SeerrAppearancesRow, SeerrCrewCreditsRow, technicalDetailsFor

Upstream made these **public** specifically so the modern layout could reuse them.
Voltix's `item_detail_screen.dart` is a 2.2.0-era file where they are private, named
differently, or not extracted at all:

| Upstream (public) | Voltix today |
|---|---|
| `DetailActionButtons` | `_ActionButtons` |
| `DetailCastRow` | `_CastRow` |
| `DetailChaptersRow` | `_ChaptersRow` |
| `DetailFeaturesRow` | `_FeaturesRow` |
| `DetailEpisodeCard` | `_EpisodeCard` |
| `DetailSimilarRow` | `_SimilarRow` |
| `DetailTrackList` | `_TrackList` |
| `ExpandableBiography` | `_ExpandableBiography` |
| `selectedMediaSourceForItem` | `_selectedMediaSourceForItem` |
| `PersonDates` | `_PersonDates` |
| `FilmographyRow` | `_FilmographyRow` |
| `SeerrAppearancesRow` | `_SeerrAppearancesRow` |
| `SeerrCrewCreditsRow` | absent |
| `technicalDetailsFor` | inline, never extracted (~line 3595) |

**Renaming is not enough.** The signatures diverged. `DetailActionButtons` upstream carries
Voltix's 9 fields plus `maxVisibleButtonsOverride`, `onArrowRightAtEnd`, `modernStyle` and
`fullWidthPrimary` — and the modern layout passes them. `modernStyle` in particular changes
the row's alignment and spacing, so it is behaviour, not plumbing. The same divergence
applies across most of the 14.

## What finishing it takes

1. Rename the 12 existing widgets to upstream's public names.
2. Add the extra constructor parameters to each, and implement the behaviour they drive
   (compare against upstream's copies of the same widgets, not just their signatures).
3. Extract `technicalDetailsFor` from the inline block near line 3595.
4. Port `SeerrCrewCreditsRow`.
5. Restore `modern/` into `lib/ui/screens/detail/`, then wire the branch in
   `item_detail_screen.dart`'s `ItemDetailState.ready` arm:
   `_prefs.get(UserPreferences.detailScreenStyle) == DetailScreenStyle.modern
    ? ModernDetailContent(...) : _DetailContent(...)`
   — upstream's version of that arm is the reference, and it needs two new state fields,
   `_showNavbar` (gates `showNavigationChrome`) and `_actionsExpanded`.

That wiring was written and verified once, then reverted; see
`lib/ui/screens/detail/item_detail_screen.dart.bak-modern` for the pre-change state.

This is a behaviour-bearing refactor of a 398 KB file across 14 widgets. It should be done
with a compiler in the loop, one widget at a time — not in a single blind pass.
