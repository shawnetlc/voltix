import 'package:flutter_test/flutter_test.dart';
import 'package:voltix/data/models/taste_profile/taste_profile_models.dart';
import 'package:voltix/data/services/taste_profile/grok_taste_ai_service.dart';

void main() {
  group('Taste Profile AI Home Row Suggestions', () {
    final aiService = GrokTasteAiService();

    TasteProfile makeProfile({
      ExplicitTasteProfile explicit = const ExplicitTasteProfile(),
      Map<String, bool> enabledHomeRows = const {},
    }) {
      final now = DateTime.now().toUtc();
      return TasteProfile(
        profileId: 'test_profile',
        serverId: 's1',
        userId: 'u1',
        profileRevision: '1',
        createdAtUtc: now,
        updatedAtUtc: now,
        lastUpdated: now,
        status: TasteProfileStatus.completed,
        explicit: explicit,
        inferred: InferredTasteProfile(),
        enabledHomeRows: enabledHomeRows,
      );
    }

    test('defaults absent rows to false', () {
      final profile = makeProfile(enabledHomeRows: {});

      for (final row in PersonalizationRowType.values) {
        expect(profile.enabledHomeRows[row.key] ?? false, isFalse);
      }
    });

    test('suggests series binge row for series fans', () {
      final profile = makeProfile(
        explicit: ExplicitTasteProfile(
          viewingPreferences: const ViewingPreferences(formatPreference: 'series'),
          titleRatings: {
            'series_1': TasteRating.love,
            'series_2': TasteRating.like,
            'series_3': TasteRating.love,
          },
          genreRatings: {
            'Drama': TasteRating.love,
          },
        ),
      );

      final rows = aiService.suggestLocalTopHomeRows(profile);
      expect(rows, contains(PersonalizationRowType.seriesYouMightBinge));
      expect(rows, contains(PersonalizationRowType.recommendedForYou));
      expect(rows.length, inInclusiveRange(3, 5));
    });

    test('suggests mood row when moods are selected', () {
      final profile = makeProfile(
        explicit: ExplicitTasteProfile(
          selectedMoods: {MoodCategory.feelGood},
          selectedMoodIds: {'feel_good'},
          genreRatings: {
            'Comedy': TasteRating.love,
          },
        ),
      );

      final rows = aiService.suggestLocalTopHomeRows(profile);
      expect(rows, contains(PersonalizationRowType.moodMatch));
      expect(rows, contains(PersonalizationRowType.recommendedForYou));
      expect(rows.length, inInclusiveRange(3, 5));
    });

    test('suggests prestige rows for drama and history lovers', () {
      final profile = makeProfile(
        explicit: ExplicitTasteProfile(
          genreRatings: {
            'Drama': TasteRating.love,
            'History': TasteRating.love,
            'Biography': TasteRating.like,
          },
        ),
      );

      final rows = aiService.suggestLocalTopHomeRows(profile);
      expect(rows, contains(PersonalizationRowType.oscarWinners));
      expect(rows.length, inInclusiveRange(3, 5));
    });

    test('suggests genre deep cuts and hidden gems for sci-fi and horror lovers', () {
      final profile = makeProfile(
        explicit: ExplicitTasteProfile(
          genreRatings: {
            'Sci-Fi': TasteRating.love,
            'Horror': TasteRating.love,
          },
        ),
      );

      final rows = aiService.suggestLocalTopHomeRows(profile);
      expect(rows, anyOf(contains(PersonalizationRowType.genreDeepCuts), contains(PersonalizationRowType.hiddenGems)));
      expect(rows.length, inInclusiveRange(3, 5));
    });
  });
}
