# Parked: ported from Moonfin 2.4.0, not reconcilable with this fork yet

Excluded from analysis via `analysis_options.yaml` (`exclude: _parked_2_4/**`), so
`flutter analyze` reflects shippable code. Nothing here is referenced from `lib/`.

## Why these are parked

The **modern detail screen** and the Seerr widget set it depends on were written against
upstream's Seerr layer, which is materially newer than this fork's. Copying them produced
~400 analyzer errors, all of the same shape: symbols that exist upstream and not here.

### Missing from this fork's Seerr layer

| Kind | Examples |
|---|---|
| Model types | `SeerrQualityStatus`, `SeerrSeason`, `SeerrQuotaDetail`, `SeerrCollectionRef`, `SeerrDownloadingItem` |
| `SeerrMediaDetailState` getters | `hd`, `uhd`, `hdDownload`, `download4k`, `quota`, `allActiveRequests` |
| `SeerrTvDetails` | `seasons` |
| `SeerrRequest` / `SeerrMedia` | `statusFailed`, `downloadStatus`, `downloadStatus4k` |
| `ItemDetailViewModel` | `seerr` |
| l10n keys (~20) | `request4k`, `requested4k`, `cancelRequest4k`, `requestErrorQuota`, `genresAndTags`, `tags`, `viewCollection`, `partOfCollectionName`, `seerrSeriesContinuing`, `seasonQuotaRemaining`, `movieQuotaRemaining`, `seerrImportingStatus`, `seerrDownloadingPercent`, … |
| Design tokens | `AppColorScheme.statusError`, `OledTuning` |
| Routes | `Destinations.seerrCollection` |

### Contents

- `_pending_modern_detail/` — the 6 `modern/` files, plus a README with the 14-symbol
  mapping table for `item_detail_screen.dart` and a finish plan.
- `lib/ui/widgets/seerr/` — 14 Seerr widgets
- `lib/ui/widgets/`, `lib/ui/theme/`, `lib/util/` — `offline_aware_image`, `image_source`,
  `glass_focus_halo`, `vibrance`, `overview_text`, `focus_scroll`,
  `seerr_download_progress_bar`
- `lib/data/services/seerr/seerr_download_progress.dart`

## Order to tackle it in

1. Port upstream's Seerr **API models** (`seerr_api_models.dart`) and
   `SeerrMediaDetailViewModel` / `SeerrMediaDetailState`. Everything else here depends on
   them, and this is the real prerequisite — not the detail screen.
2. Add the ~20 l10n keys, `AppColorScheme.statusError`, `OledTuning`,
   `Destinations.seerrCollection`.
3. Restore the Seerr widgets from here, one at a time, running analyze between each.
4. Only then the modern detail screen, which additionally needs the 14 widgets in
   `item_detail_screen.dart` made public with upstream's signatures.

Doing this in the reverse order — detail screen first — is what produced the 400 errors.
