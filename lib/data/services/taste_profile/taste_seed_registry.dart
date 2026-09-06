import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../../preference/user_preferences.dart';
import '../../models/aggregated_item.dart';

/// Hands out "because you watched X" seeds so that two rows never pick the
/// same title.
///
/// Voltix Recommends already builds seeded rows from recently-watched titles,
/// and it is staying on alongside the taste profile's own seeded row. Both
/// draw from the same short list of what you last finished, so without a
/// shared claim they would routinely land on the same film and the home screen
/// would show it twice under two different headings.
///
/// Voltix Recommends selects by position — row 1 takes the most recent title,
/// row 2 the next, and so on up to `sinceYouWatchedNumRows`. Rather than
/// change that (it works, and rewriting it to claim seeds would risk a row
/// people already rely on), this registry treats those leading positions as
/// spoken for and serves taste rows from behind them.
class TasteSeedRegistry {
  /// How far down the recently-watched list to look. Deep enough to clear the
  /// positions Voltix Recommends reserves and still leave room to rotate.
  static const _poolSize = 20;

  /// How long a claim holds. Long enough that a rebuild triggered by finishing
  /// an episode does not immediately re-serve the same seed, short enough that
  /// the row still changes over a day of viewing.
  static const _claimTtl = Duration(hours: 12);

  final Map<String, DateTime> _claims = {};
  List<AggregatedItem>? _pool;
  DateTime? _poolFetchedAt;
  static const _poolTtl = Duration(minutes: 30);

  /// Positions Voltix Recommends will consume from the top of the list.
  ///
  /// Reads the same preference that screen does, so raising the row count
  /// there automatically pushes taste seeds further down instead of silently
  /// creating a collision.
  int get reservedCount {
    try {
      if (!GetIt.instance.isRegistered<UserPreferences>()) return 1;
      return GetIt.instance<UserPreferences>()
          .get(UserPreferences.sinceYouWatchedNumRows)
          .value;
    } catch (_) {
      return 1;
    }
  }

  /// A title to build a seeded row from, or null when there is nothing
  /// unclaimed to use.
  ///
  /// Prefers the least recently claimed candidate so the row rotates across
  /// rebuilds rather than showing the same film until it falls out of the
  /// watch list.
  Future<AggregatedItem?> claimSeed({
    required MediaServerClient client,
    required String serverId,
  }) async {
    final pool = await _recentlyWatched(client: client, serverId: serverId);
    if (pool.isEmpty) return null;

    _expireClaims();

    // Skip the leading positions Voltix Recommends is using.
    final available = pool.skip(reservedCount).toList();
    if (available.isEmpty) return null;

    final unclaimed = available.where((i) => !_claims.containsKey(i.id));
    final choice = unclaimed.isNotEmpty
        ? unclaimed.first
        // Everything is claimed, so reuse the oldest claim rather than
        // dropping the row entirely.
        : (available..sort((a, b) => (_claims[a.id] ?? DateTime(0))
            .compareTo(_claims[b.id] ?? DateTime(0)))).first;

    _claims[choice.id] = DateTime.now();
    return choice;
  }

  /// Releases a claim, for when a row using it was dropped.
  void release(String itemId) => _claims.remove(itemId);

  void clear() {
    _claims.clear();
    _pool = null;
    _poolFetchedAt = null;
  }

  void _expireClaims() {
    final now = DateTime.now();
    _claims.removeWhere((_, at) => now.difference(at) > _claimTtl);
  }

  /// Recently finished titles, newest first.
  ///
  /// Episodes are resolved to their series: "because you watched episode 4 of
  /// something" is not a useful heading, and recommending against a single
  /// episode gives worse neighbours than recommending against the show.
  Future<List<AggregatedItem>> _recentlyWatched({
    required MediaServerClient client,
    required String serverId,
  }) async {
    final cached = _pool;
    final fetchedAt = _poolFetchedAt;
    if (cached != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _poolTtl) {
      return cached;
    }

    try {
      final res = await client.itemsApi.getItems(
        recursive: true,
        includeItemTypes: const ['Movie', 'Episode'],
        filters: const ['IsPlayed'],
        sortBy: 'DatePlayed',
        sortOrder: 'Descending',
        fields: 'Genres,People,ProviderIds,SeriesId,ProductionYear,ImageTags',
        limit: _poolSize * 2,
      );

      final raw = (res['Items'] as List? ?? []).whereType<Map<String, dynamic>>();
      final seeds = <AggregatedItem>[];
      final seenSeries = <String>{};

      for (final r in raw) {
        final id = r['Id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final item = AggregatedItem(id: id, serverId: serverId, rawData: r);

        if (item.type == 'Episode') {
          final seriesId = r['SeriesId']?.toString();
          // One seed per series: five episodes of the same show in a night
          // should not fill the pool with five copies of it.
          if (seriesId == null || seriesId.isEmpty) continue;
          if (!seenSeries.add(seriesId)) continue;
          seeds.add(
            AggregatedItem(
              id: seriesId,
              serverId: serverId,
              rawData: {
                'Id': seriesId,
                'Name': r['SeriesName'] ?? item.name,
                'Type': 'Series',
              },
            ),
          );
        } else {
          seeds.add(item);
        }
        if (seeds.length >= _poolSize) break;
      }

      _pool = seeds;
      _poolFetchedAt = DateTime.now();
      return seeds;
    } catch (e) {
      debugPrint('[TasteSeedRegistry] recently-watched lookup failed: $e');
      return cached ?? const [];
    }
  }
}
