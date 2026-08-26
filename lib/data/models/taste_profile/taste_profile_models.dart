import 'package:uuid/uuid.dart';
import '../aggregated_item.dart';
export 'taste_options_registry.dart';

/// Rating given to a title during onboarding or in profile editing.
enum TasteRating {
  love('love'),
  like('like'),
  neutral('neutral'),
  dislike('dislike'),
  unseen('unseen');

  final String value;
  const TasteRating(this.value);

  static TasteRating fromString(String? val) {
    if (val == null) return TasteRating.neutral;
    for (final r in TasteRating.values) {
      if (r.value.toLowerCase() == val.toLowerCase()) return r;
    }
    return TasteRating.neutral;
  }
}

/// Mood categories for dynamic mood-based recommendations.
enum MoodCategory {
  edgeOfYourSeat('Edge-of-Your-Seat', 'thrill, intense, suspenseful, adrenaline'),
  feelGood('Feel-Good', 'uplifting, heartwarming, lighthearted, cheerful'),
  thoughtProvoking('Thought-Provoking', 'philosophical, deep, complex, mind-bending'),
  scary('Scary & Eerie', 'horror, supernatural, psychological, dark'),
  funny('Laugh-Out-Loud', 'comedy, hilarious, witty, parody'),
  epic('Epic & Grand', 'adventure, historical, sci-fi saga, superhero'),
  romantic('Romantic & Intimate', 'romance, drama, passionate, relationship'),
  mindBending('Mind-Bending & Mystery', 'mystery, puzzle, sci-fi, twist');

  final String label;
  final String keywords;
  const MoodCategory(this.label, this.keywords);

  static MoodCategory fromString(String? val) {
    if (val == null) return MoodCategory.feelGood;
    for (final m in MoodCategory.values) {
      if (m.name.toLowerCase() == val.toLowerCase() ||
          m.label.toLowerCase() == val.toLowerCase()) {
        return m;
      }
    }
    return MoodCategory.feelGood;
  }
}

/// User's language and foreign content filtering preferences.
class LanguageSettings {
  final bool excludeForeignContent; // default: true
  final Set<String> allowedOriginalLanguages; // default: {'eng', 'en'}
  final Set<String> allowedAudioLanguages; // default: {'eng', 'en'}
  final bool includeSubtitled; // default: false
  final bool allowForeignFallback; // default: false
  final double foreignFallbackThreshold; // default: 0.3
  final bool allowUnknownLanguage; // default: true

  const LanguageSettings({
    this.excludeForeignContent = true,
    this.allowedOriginalLanguages = const {'eng', 'en', 'english'},
    this.allowedAudioLanguages = const {'eng', 'en', 'english'},
    this.includeSubtitled = false,
    this.allowForeignFallback = false,
    this.foreignFallbackThreshold = 0.3,
    this.allowUnknownLanguage = true,
  });

  Map<String, dynamic> toJson() => {
        'excludeForeignContent': excludeForeignContent,
        'allowedOriginalLanguages': allowedOriginalLanguages.toList(),
        'allowedAudioLanguages': allowedAudioLanguages.toList(),
        'includeSubtitled': includeSubtitled,
        'allowForeignFallback': allowForeignFallback,
        'foreignFallbackThreshold': foreignFallbackThreshold,
        'allowUnknownLanguage': allowUnknownLanguage,
      };

  factory LanguageSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const LanguageSettings();
    return LanguageSettings(
      excludeForeignContent: json['excludeForeignContent'] as bool? ?? true,
      allowedOriginalLanguages: (json['allowedOriginalLanguages'] as List<dynamic>?)
              ?.map((e) => e.toString().toLowerCase())
              .toSet() ??
          const {'eng', 'en'},
      allowedAudioLanguages: (json['allowedAudioLanguages'] as List<dynamic>?)
              ?.map((e) => e.toString().toLowerCase())
              .toSet() ??
          const {'eng', 'en'},
      includeSubtitled: json['includeSubtitled'] as bool? ?? false,
      allowForeignFallback: json['allowForeignFallback'] as bool? ?? false,
      foreignFallbackThreshold:
          (json['foreignFallbackThreshold'] as num?)?.toDouble() ?? 0.3,
      allowUnknownLanguage: json['allowUnknownLanguage'] as bool? ?? false,
    );
  }

  LanguageSettings copyWith({
    bool? excludeForeignContent,
    Set<String>? allowedOriginalLanguages,
    Set<String>? allowedAudioLanguages,
    bool? includeSubtitled,
    bool? allowForeignFallback,
    double? foreignFallbackThreshold,
    bool? allowUnknownLanguage,
  }) =>
      LanguageSettings(
        excludeForeignContent:
            excludeForeignContent ?? this.excludeForeignContent,
        allowedOriginalLanguages:
            allowedOriginalLanguages ?? this.allowedOriginalLanguages,
        allowedAudioLanguages:
            allowedAudioLanguages ?? this.allowedAudioLanguages,
        includeSubtitled: includeSubtitled ?? this.includeSubtitled,
        allowForeignFallback:
            allowForeignFallback ?? this.allowForeignFallback,
        foreignFallbackThreshold:
            foreignFallbackThreshold ?? this.foreignFallbackThreshold,
        allowUnknownLanguage:
            allowUnknownLanguage ?? this.allowUnknownLanguage,
      );
}

/// Dynamically discovered genre from the primary server's active library.
class ServerGenreInfo {
  final String key; // trimmed lowercase key for consistent lookup
  final String label; // original server display label
  final int libraryCount; // count of eligible titles in library
  final int watchedCount; // count of titles watched by the user

  const ServerGenreInfo({
    required this.key,
    required this.label,
    this.libraryCount = 0,
    this.watchedCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'libraryCount': libraryCount,
        'watchedCount': watchedCount,
      };

  factory ServerGenreInfo.fromJson(Map<String, dynamic> json) =>
      ServerGenreInfo(
        key: json['key'] as String? ?? '',
        label: json['label'] as String? ?? '',
        libraryCount: (json['libraryCount'] as num?)?.toInt() ?? 0,
        watchedCount: (json['watchedCount'] as num?)?.toInt() ?? 0,
      );
}

/// User's broad viewing habits and format preferences.
class ViewingPreferences {
  final String formatPreference; // 'both', 'movies', 'series'
  final int maxMovieLengthMinutes; // e.g. 90, 120, 180, 0 for any
  final String preferredEra; // 'all', 'classic' (<1980), 'modern' (1980-2010), 'recent' (>2010)
  final String subtitlesPreference; // 'yes', 'no', 'sometimes'
  final String maturityCeiling; // 'G', 'PG', 'PG-13', 'R', 'NC-17', 'Any'
  final String pacingPreference; // 'fast', 'moderate', 'slow-burn', 'any'
  final Set<String> selectedPreferenceIds;
  final Map<String, String> preferenceValues;

  const ViewingPreferences({
    this.formatPreference = 'both',
    this.maxMovieLengthMinutes = 0,
    this.preferredEra = 'all',
    this.subtitlesPreference = 'sometimes',
    this.maturityCeiling = 'Any',
    this.pacingPreference = 'any',
    this.selectedPreferenceIds = const {},
    this.preferenceValues = const {},
  });

  Map<String, dynamic> toJson() => {
        'formatPreference': formatPreference,
        'maxMovieLengthMinutes': maxMovieLengthMinutes,
        'preferredEra': preferredEra,
        'subtitlesPreference': subtitlesPreference,
        'maturityCeiling': maturityCeiling,
        'pacingPreference': pacingPreference,
        'selectedPreferenceIds': selectedPreferenceIds.toList(),
        'preferenceValues': preferenceValues,
      };

  factory ViewingPreferences.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ViewingPreferences();

    final format = json['formatPreference'] as String? ?? 'both';
    final maxLen = (json['maxMovieLengthMinutes'] as num?)?.toInt() ?? 0;
    final era = json['preferredEra'] as String? ?? 'all';
    final subs = json['subtitlesPreference'] as String? ?? 'sometimes';
    final maturity = json['maturityCeiling'] as String? ?? 'Any';
    final pacing = json['pacingPreference'] as String? ?? 'any';

    final prefIdsRaw = json['selectedPreferenceIds'] as List<dynamic>?;
    final Set<String> prefIds;
    if (prefIdsRaw != null) {
      prefIds = prefIdsRaw.map((e) => e.toString()).toSet();
    } else {
      // Migrate from legacy fields into standard preference IDs
      prefIds = <String>{};
      if (format == 'movies') prefIds.add('fmt_movies_only');
      if (format == 'series') prefIds.add('fmt_series_only');
      if (format == 'both') prefIds.add('fmt_movies_series_equal');
      if (era == 'classic') prefIds.add('era_mostly_classic');
      if (era == 'modern') prefIds.add('era_mostly_modern');
      if (era == 'recent') prefIds.add('era_recent_only');
      if (era == 'all') prefIds.add('era_no_preference');
      if (maxLen == 90) prefIds.add('fmt_runtime_under_90');
      if (maxLen == 120) prefIds.add('fmt_runtime_90_120');
      if (maxLen == 180) prefIds.add('fmt_runtime_over_120');
      if (maxLen == 0) prefIds.add('fmt_runtime_no_preference');
    }

    final valuesRaw = json['preferenceValues'] as Map<String, dynamic>? ?? {};
    final values = valuesRaw.map((k, v) => MapEntry(k, v.toString()));

    return ViewingPreferences(
      formatPreference: format,
      maxMovieLengthMinutes: maxLen,
      preferredEra: era,
      subtitlesPreference: subs,
      maturityCeiling: maturity,
      pacingPreference: pacing,
      selectedPreferenceIds: prefIds,
      preferenceValues: values,
    );
  }

  ViewingPreferences copyWith({
    String? formatPreference,
    int? maxMovieLengthMinutes,
    String? preferredEra,
    String? subtitlesPreference,
    String? maturityCeiling,
    String? pacingPreference,
    Set<String>? selectedPreferenceIds,
    Map<String, String>? preferenceValues,
  }) =>
      ViewingPreferences(
        formatPreference: formatPreference ?? this.formatPreference,
        maxMovieLengthMinutes:
            maxMovieLengthMinutes ?? this.maxMovieLengthMinutes,
        preferredEra: preferredEra ?? this.preferredEra,
        subtitlesPreference: subtitlesPreference ?? this.subtitlesPreference,
        maturityCeiling: maturityCeiling ?? this.maturityCeiling,
        pacingPreference: pacingPreference ?? this.pacingPreference,
        selectedPreferenceIds:
            selectedPreferenceIds ?? this.selectedPreferenceIds,
        preferenceValues: preferenceValues ?? this.preferenceValues,
      );
}

/// Explicit answers given directly by the user in the questionnaire.
class ExplicitTasteProfile {
  final Map<String, TasteRating> titleRatings; // itemId -> rating
  final Map<String, String> titleNames; // itemId -> human readable title name
  final Map<String, TasteRating> genreRatings; // Genre Name / Key -> rating
  final ViewingPreferences viewingPreferences;
  final Set<MoodCategory> selectedMoods;
  final Set<String> selectedMoodIds;
  final String? freeTextDescription;
  final DateTime? completedAt;

  const ExplicitTasteProfile({
    this.titleRatings = const {},
    this.titleNames = const {},
    this.genreRatings = const {},
    this.viewingPreferences = const ViewingPreferences(),
    this.selectedMoods = const {},
    this.selectedMoodIds = const {},
    this.freeTextDescription,
    this.completedAt,
  });

  Map<String, dynamic> toJson() => {
        'titleRatings': titleRatings.map((k, v) => MapEntry(k, v.value)),
        'titleNames': titleNames,
        'genreRatings': genreRatings.map((k, v) => MapEntry(k, v.value)),
        'viewingPreferences': viewingPreferences.toJson(),
        'selectedMoods': selectedMoods.map((m) => m.name).toList(),
        'selectedMoodIds': selectedMoodIds.toList(),
        'freeTextDescription': freeTextDescription,
        'completedAt': completedAt?.toIso8601String(),
      };

  factory ExplicitTasteProfile.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ExplicitTasteProfile();

    final titlesRaw = json['titleRatings'] as Map<String, dynamic>? ?? {};
    final titles = titlesRaw.map(
      (k, v) => MapEntry(k, TasteRating.fromString(v?.toString())),
    );

    final titleNamesRaw = json['titleNames'] as Map<String, dynamic>? ?? {};
    final titleNames = titleNamesRaw.map(
      (k, v) => MapEntry(k, v?.toString() ?? ''),
    );

    final genresRaw = json['genreRatings'] as Map<String, dynamic>? ?? {};
    final genres = genresRaw.map(
      (k, v) => MapEntry(k, TasteRating.fromString(v?.toString())),
    );

    final moodsRaw = json['selectedMoods'] as List<dynamic>? ?? [];
    final moods = moodsRaw
        .map((m) => MoodCategory.fromString(m?.toString()))
        .toSet();

    final moodIdsRaw = json['selectedMoodIds'] as List<dynamic>?;
    final Set<String> moodIds;
    if (moodIdsRaw != null) {
      moodIds = moodIdsRaw.map((e) => e.toString()).toSet();
    } else {
      // Map legacy MoodCategory enums to standard mood IDs
      moodIds = <String>{};
      for (final m in moods) {
        switch (m) {
          case MoodCategory.edgeOfYourSeat:
            moodIds.add('mood_high_octane');
            break;
          case MoodCategory.feelGood:
            moodIds.add('mood_uplifting');
            break;
          case MoodCategory.thoughtProvoking:
            moodIds.add('mood_thought_provoking');
            break;
          case MoodCategory.scary:
            moodIds.add('mood_ominous');
            break;
          case MoodCategory.funny:
            moodIds.add('mood_feel_good_comedy');
            break;
          case MoodCategory.epic:
            moodIds.add('mood_grand');
            break;
          case MoodCategory.romantic:
            moodIds.add('mood_romantic');
            break;
          case MoodCategory.mindBending:
            moodIds.add('mood_mind_bending');
            break;
        }
      }
    }

    return ExplicitTasteProfile(
      titleRatings: titles,
      titleNames: titleNames,
      genreRatings: genres,
      viewingPreferences:
          ViewingPreferences.fromJson(json['viewingPreferences'] as Map<String, dynamic>?),
      selectedMoods: moods,
      selectedMoodIds: moodIds,
      freeTextDescription: json['freeTextDescription'] as String?,
      completedAt: json['completedAt'] != null
          ? DateTime.tryParse(json['completedAt'] as String)
          : null,
    );
  }

  ExplicitTasteProfile copyWith({
    Map<String, TasteRating>? titleRatings,
    Map<String, String>? titleNames,
    Map<String, TasteRating>? genreRatings,
    ViewingPreferences? viewingPreferences,
    Set<MoodCategory>? selectedMoods,
    Set<String>? selectedMoodIds,
    String? freeTextDescription,
    DateTime? completedAt,
  }) =>
      ExplicitTasteProfile(
        titleRatings: titleRatings ?? this.titleRatings,
        titleNames: titleNames ?? this.titleNames,
        genreRatings: genreRatings ?? this.genreRatings,
        viewingPreferences: viewingPreferences ?? this.viewingPreferences,
        selectedMoods: selectedMoods ?? this.selectedMoods,
        selectedMoodIds: selectedMoodIds ?? this.selectedMoodIds,
        freeTextDescription: freeTextDescription ?? this.freeTextDescription,
        completedAt: completedAt ?? this.completedAt,
      );
}

/// Inferred signals computed purely from watch history & library interactions.
class InferredTasteProfile {
  final Map<String, double> genreAffinities; // normalized 0.0 - 1.0
  final Map<String, double> actorAffinities; // actor name -> weight
  final Map<String, double> directorAffinities; // director name -> weight
  final Map<String, double> studioAffinities; // studio -> weight
  final Map<String, double> moodAffinities; // mood name -> weight
  final Map<String, double> eraAffinities; // era -> weight
  final double bingeScore; // 0.0 - 1.0 series binge tendency
  final double rewatchScore; // tendency to replay
  final Set<String> negativeGenreSignals;
  final Set<String> negativePeopleSignals;
  final DateTime computedAt;

  InferredTasteProfile({
    this.genreAffinities = const {},
    this.actorAffinities = const {},
    this.directorAffinities = const {},
    this.studioAffinities = const {},
    this.moodAffinities = const {},
    this.eraAffinities = const {},
    this.bingeScore = 0.5,
    this.rewatchScore = 0.0,
    this.negativeGenreSignals = const {},
    this.negativePeopleSignals = const {},
    DateTime? computedAt,
  }) : computedAt = computedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'genreAffinities': genreAffinities,
        'actorAffinities': actorAffinities,
        'directorAffinities': directorAffinities,
        'studioAffinities': studioAffinities,
        'moodAffinities': moodAffinities,
        'eraAffinities': eraAffinities,
        'bingeScore': bingeScore,
        'rewatchScore': rewatchScore,
        'negativeGenreSignals': negativeGenreSignals.toList(),
        'negativePeopleSignals': negativePeopleSignals.toList(),
        'computedAt': computedAt.toIso8601String(),
      };

  factory InferredTasteProfile.fromJson(Map<String, dynamic>? json) {
    if (json == null) return InferredTasteProfile();

    Map<String, double> toDoubleMap(dynamic raw) {
      if (raw is! Map) return {};
      return raw.map(
        (k, v) => MapEntry(k.toString(), (v as num?)?.toDouble() ?? 0.0),
      );
    }

    Set<String> toStringSet(dynamic raw) {
      if (raw is! List) return {};
      return raw.map((e) => e.toString()).toSet();
    }

    return InferredTasteProfile(
      genreAffinities: toDoubleMap(json['genreAffinities']),
      actorAffinities: toDoubleMap(json['actorAffinities']),
      directorAffinities: toDoubleMap(json['directorAffinities']),
      studioAffinities: toDoubleMap(json['studioAffinities']),
      moodAffinities: toDoubleMap(json['moodAffinities']),
      eraAffinities: toDoubleMap(json['eraAffinities']),
      bingeScore: (json['bingeScore'] as num?)?.toDouble() ?? 0.5,
      rewatchScore: (json['rewatchScore'] as num?)?.toDouble() ?? 0.0,
      negativeGenreSignals: toStringSet(json['negativeGenreSignals']),
      negativePeopleSignals: toStringSet(json['negativePeopleSignals']),
      computedAt: json['computedAt'] != null
          ? DateTime.tryParse(json['computedAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

/// A negative user feedback signal ("Not Interested").
class NegativeSignal {
  final String id;
  final String title;
  final String type; // 'item', 'genre', 'person'
  final DateTime createdAt;

  const NegativeSignal({
    required this.id,
    required this.title,
    required this.type,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type,
        'createdAt': createdAt.toIso8601String(),
      };

  factory NegativeSignal.fromJson(Map<String, dynamic> json) => NegativeSignal(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        type: json['type'] as String? ?? 'item',
        createdAt: json['createdAt'] != null
            ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
            : DateTime.now(),
      );
}

/// A user feedback event ("More like this", "Watched Elsewhere", etc.).
class FeedbackSignal {
  final String eventId;
  final String itemId;
  final String action; // 'moreLikeThis', 'lessLikeThis', 'seenIt'
  final DateTime timestamp;

  const FeedbackSignal({
    required this.eventId,
    required this.itemId,
    required this.action,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'eventId': eventId,
        'itemId': itemId,
        'action': action,
        'timestamp': timestamp.toIso8601String(),
      };

  factory FeedbackSignal.fromJson(Map<String, dynamic> json) => FeedbackSignal(
        eventId: json['eventId'] as String? ?? const Uuid().v4(),
        itemId: json['itemId'] as String? ?? '',
        action: json['action'] as String? ?? '',
        timestamp: json['timestamp'] != null
            ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
            : DateTime.now(),
      );
}

/// Status of the user's taste profile onboarding.
enum TasteProfileStatus {
  notStarted('notStarted'),
  inProgress('inProgress'),
  skippedRemindMe('skippedRemindMe'),
  completed('completed');

  final String value;
  const TasteProfileStatus(this.value);

  static TasteProfileStatus fromString(String? val) {
    if (val == null) return TasteProfileStatus.notStarted;
    for (final s in TasteProfileStatus.values) {
      if (s.value == val) return s;
    }
    return TasteProfileStatus.notStarted;
  }
}

/// Cloud sync lifecycle status for Azure Blob backup.
enum SyncStatus {
  localOnly('LocalOnly'),
  pendingUpload('PendingUpload'),
  synced('Synced'),
  conflict('Conflict'),
  importRequired('ImportRequired');

  final String value;
  const SyncStatus(this.value);

  static SyncStatus fromString(String? val) {
    if (val == null) return SyncStatus.localOnly;
    for (final s in SyncStatus.values) {
      if (s.value.toLowerCase() == val.toLowerCase()) return s;
    }
    return SyncStatus.localOnly;
  }
}

/// Client device metadata.
class ClientMetadata {
  final String clientId;
  final String deviceId;
  final String appVersion;

  const ClientMetadata({
    this.clientId = 'voltix-jellyfin-client',
    this.deviceId = 'generic-device',
    this.appVersion = '1.0.0',
  });

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'deviceId': deviceId,
        'appVersion': appVersion,
      };

  factory ClientMetadata.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ClientMetadata();
    return ClientMetadata(
      clientId: json['clientId'] as String? ?? 'voltix-jellyfin-client',
      deviceId: json['deviceId'] as String? ?? 'generic-device',
      appVersion: json['appVersion'] as String? ?? '1.0.0',
    );
  }
}

/// Unified versioned profile document (schemaVersion: 1).
class TasteProfile {
  final int schemaVersion; // 1
  final String profileId;
  final String serverId; // primary server ID
  final String serverUrlHash;
  final String userId;
  final int profileVersion;
  final String profileRevision;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final DateTime? lastSyncedAtUtc;
  final SyncStatus syncStatus;
  final TasteProfileStatus status;
  final ExplicitTasteProfile explicit;
  final InferredTasteProfile inferred;
  final LanguageSettings languageSettings;
  final List<NegativeSignal> negativeSignals;
  final List<FeedbackSignal> feedbackSignals;
  final Map<String, bool> enabledHomeRows;
  final List<String> rowOrder;
  final int maxItemsPerRow;
  final bool aiFeaturesEnabled;
  final String? aiPersonaSummary;
  final DateTime? aiLastInsightUtc;
  final bool azureBackupEnabled;
  final ClientMetadata clientMetadata;
  final DateTime lastUpdated;

  const TasteProfile({
    this.schemaVersion = 2,
    required this.profileId,
    required this.serverId,
    this.serverUrlHash = '',
    required this.userId,
    this.profileVersion = 1,
    required this.profileRevision,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.lastSyncedAtUtc,
    this.syncStatus = SyncStatus.localOnly,
    this.status = TasteProfileStatus.notStarted,
    this.explicit = const ExplicitTasteProfile(),
    required this.inferred,
    this.languageSettings = const LanguageSettings(),
    this.negativeSignals = const [],
    this.feedbackSignals = const [],
    this.enabledHomeRows = const {},
    this.rowOrder = const [],
    this.maxItemsPerRow = 20,
    this.aiFeaturesEnabled = true,
    this.aiPersonaSummary,
    this.aiLastInsightUtc,
    this.azureBackupEnabled = true,
    this.clientMetadata = const ClientMetadata(),
    required this.lastUpdated,
  });

  bool get isCompleted => status == TasteProfileStatus.completed;
  bool get isSkipped => status == TasteProfileStatus.skippedRemindMe;

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'profileId': profileId,
        'serverId': serverId,
        'serverUrlHash': serverUrlHash,
        'userId': userId,
        'profileVersion': profileVersion,
        'profileRevision': profileRevision,
        'createdAtUtc': createdAtUtc.toIso8601String(),
        'updatedAtUtc': updatedAtUtc.toIso8601String(),
        'lastSyncedAtUtc': lastSyncedAtUtc?.toIso8601String(),
        'syncStatus': syncStatus.value,
        'status': status.value,
        'explicit': explicit.toJson(),
        'inferred': inferred.toJson(),
        'languageSettings': languageSettings.toJson(),
        'negativeSignals': negativeSignals.map((n) => n.toJson()).toList(),
        'feedbackSignals': feedbackSignals.map((f) => f.toJson()).toList(),
        'enabledHomeRows': enabledHomeRows,
        'rowOrder': rowOrder,
        'maxItemsPerRow': maxItemsPerRow,
        'aiFeaturesEnabled': aiFeaturesEnabled,
        'aiPersonaSummary': aiPersonaSummary,
        'aiLastInsightUtc': aiLastInsightUtc?.toIso8601String(),
        'azureBackupEnabled': azureBackupEnabled,
        'clientMetadata': clientMetadata.toJson(),
        'lastUpdated': lastUpdated.toIso8601String(),
      };

  factory TasteProfile.fromJson(Map<String, dynamic> json) {
    final negRaw = json['negativeSignals'] as List<dynamic>? ?? [];
    final neg = negRaw
        .whereType<Map<String, dynamic>>()
        .map(NegativeSignal.fromJson)
        .toList();

    final feedRaw = json['feedbackSignals'] as List<dynamic>? ?? [];
    final feed = feedRaw
        .whereType<Map<String, dynamic>>()
        .map(FeedbackSignal.fromJson)
        .toList();

    final rowsRaw = json['enabledHomeRows'] as Map<String, dynamic>? ?? {};
    final rows = rowsRaw.map((k, v) => MapEntry(k, v == true));

    final rowOrderRaw = json['rowOrder'] as List<dynamic>? ?? [];
    final rowOrder = rowOrderRaw.map((e) => e.toString()).toList();

    final now = DateTime.now().toUtc();
    final createdAt = json['createdAtUtc'] != null
        ? DateTime.tryParse(json['createdAtUtc'] as String) ?? now
        : now;
    final updatedAt = json['updatedAtUtc'] != null
        ? DateTime.tryParse(json['updatedAtUtc'] as String) ?? now
        : now;

    return TasteProfile(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      profileId: json['profileId'] as String? ?? const Uuid().v4(),
      serverId: json['serverId'] as String? ?? '',
      serverUrlHash: json['serverUrlHash'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      profileVersion: (json['profileVersion'] as num?)?.toInt() ?? 1,
      profileRevision: json['profileRevision'] as String? ?? const Uuid().v4(),
      createdAtUtc: createdAt,
      updatedAtUtc: updatedAt,
      lastSyncedAtUtc: json['lastSyncedAtUtc'] != null
          ? DateTime.tryParse(json['lastSyncedAtUtc'] as String)
          : null,
      syncStatus: SyncStatus.fromString(json['syncStatus'] as String?),
      status: TasteProfileStatus.fromString(json['status'] as String?),
      explicit: ExplicitTasteProfile.fromJson(
        json['explicit'] as Map<String, dynamic>?,
      ),
      inferred: InferredTasteProfile.fromJson(
        json['inferred'] as Map<String, dynamic>?,
      ),
      languageSettings: LanguageSettings.fromJson(
        json['languageSettings'] as Map<String, dynamic>?,
      ),
      negativeSignals: neg,
      feedbackSignals: feed,
      enabledHomeRows: rows,
      rowOrder: rowOrder,
      maxItemsPerRow: (json['maxItemsPerRow'] as num?)?.toInt() ?? 20,
      aiFeaturesEnabled: json['aiFeaturesEnabled'] as bool? ?? true,
      aiPersonaSummary: json['aiPersonaSummary'] as String?,
      aiLastInsightUtc: json['aiLastInsightUtc'] != null
          ? DateTime.tryParse(json['aiLastInsightUtc'] as String)
          : null,
      azureBackupEnabled: json['azureBackupEnabled'] as bool? ?? true,
      clientMetadata: ClientMetadata.fromJson(
        json['clientMetadata'] as Map<String, dynamic>?,
      ),
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.tryParse(json['lastUpdated'] as String) ?? now
          : now,
    );
  }

  TasteProfile copyWith({
    int? schemaVersion,
    String? profileId,
    String? serverId,
    String? serverUrlHash,
    String? userId,
    int? profileVersion,
    String? profileRevision,
    DateTime? createdAtUtc,
    DateTime? updatedAtUtc,
    DateTime? lastSyncedAtUtc,
    SyncStatus? syncStatus,
    TasteProfileStatus? status,
    ExplicitTasteProfile? explicit,
    InferredTasteProfile? inferred,
    LanguageSettings? languageSettings,
    List<NegativeSignal>? negativeSignals,
    List<FeedbackSignal>? feedbackSignals,
    Map<String, bool>? enabledHomeRows,
    List<String>? rowOrder,
    int? maxItemsPerRow,
    bool? aiFeaturesEnabled,
    String? aiPersonaSummary,
    DateTime? aiLastInsightUtc,
    bool? azureBackupEnabled,
    ClientMetadata? clientMetadata,
    DateTime? lastUpdated,
  }) =>
      TasteProfile(
        schemaVersion: schemaVersion ?? this.schemaVersion,
        profileId: profileId ?? this.profileId,
        serverId: serverId ?? this.serverId,
        serverUrlHash: serverUrlHash ?? this.serverUrlHash,
        userId: userId ?? this.userId,
        profileVersion: profileVersion ?? this.profileVersion,
        profileRevision: profileRevision ?? this.profileRevision,
        createdAtUtc: createdAtUtc ?? this.createdAtUtc,
        updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
        lastSyncedAtUtc: lastSyncedAtUtc ?? this.lastSyncedAtUtc,
        syncStatus: syncStatus ?? this.syncStatus,
        status: status ?? this.status,
        explicit: explicit ?? this.explicit,
        inferred: inferred ?? this.inferred,
        languageSettings: languageSettings ?? this.languageSettings,
        negativeSignals: negativeSignals ?? this.negativeSignals,
        feedbackSignals: feedbackSignals ?? this.feedbackSignals,
        enabledHomeRows: enabledHomeRows ?? this.enabledHomeRows,
        rowOrder: rowOrder ?? this.rowOrder,
        maxItemsPerRow: maxItemsPerRow ?? this.maxItemsPerRow,
        aiFeaturesEnabled: aiFeaturesEnabled ?? this.aiFeaturesEnabled,
        aiPersonaSummary: aiPersonaSummary ?? this.aiPersonaSummary,
        aiLastInsightUtc: aiLastInsightUtc ?? this.aiLastInsightUtc,
        azureBackupEnabled: azureBackupEnabled ?? this.azureBackupEnabled,
        clientMetadata: clientMetadata ?? this.clientMetadata,
        lastUpdated: lastUpdated ?? this.lastUpdated,
      );
}

/// Breakdown of WellKnownScore computation.
class WellKnownScoreBreakdown {
  final double popularityScore;
  final double ratingConfidenceScore;
  final double completionOrWatchScore;
  final double franchiseScore;
  final double metadataCompletenessScore;
  final double totalScore;

  const WellKnownScoreBreakdown({
    required this.popularityScore,
    required this.ratingConfidenceScore,
    required this.completionOrWatchScore,
    required this.franchiseScore,
    required this.metadataCompletenessScore,
    required this.totalScore,
  });

  Map<String, double> toMap() => {
        'popularity': popularityScore,
        'ratingConfidence': ratingConfidenceScore,
        'completion': completionOrWatchScore,
        'franchise': franchiseScore,
        'metadataCompleteness': metadataCompletenessScore,
        'total': totalScore,
      };
}

/// Role of a media server in the priority hierarchy.
enum ServerRole {
  primary('Primary'),
  fourK('4K Server'),
  extra('Extra Server');

  final String label;
  const ServerRole(this.label);
}

/// Representation of an individual media copy on a specific Jellyfin server.
class ServerMediaCopy {
  final String serverId;
  final String serverName;
  final String itemId;
  final ServerRole role;
  final bool isPrimary;
  final bool isFailover;
  final bool is4K;
  final int failedPlaybackCount;
  final bool isSuppressed;
  final Map<String, dynamic> rawData;

  const ServerMediaCopy({
    required this.serverId,
    required this.serverName,
    required this.itemId,
    this.role = ServerRole.primary,
    this.isPrimary = true,
    this.isFailover = false,
    this.is4K = false,
    this.failedPlaybackCount = 0,
    this.isSuppressed = false,
    this.rawData = const {},
  });

  ServerMediaCopy copyWith({
    String? serverId,
    String? serverName,
    String? itemId,
    ServerRole? role,
    bool? isPrimary,
    bool? isFailover,
    bool? is4K,
    int? failedPlaybackCount,
    bool? isSuppressed,
    Map<String, dynamic>? rawData,
  }) =>
      ServerMediaCopy(
        serverId: serverId ?? this.serverId,
        serverName: serverName ?? this.serverName,
        itemId: itemId ?? this.itemId,
        role: role ?? this.role,
        isPrimary: isPrimary ?? this.isPrimary,
        isFailover: isFailover ?? this.isFailover,
        is4K: is4K ?? this.is4K,
        failedPlaybackCount: failedPlaybackCount ?? this.failedPlaybackCount,
        isSuppressed: isSuppressed ?? this.isSuppressed,
        rawData: rawData ?? this.rawData,
      );

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'serverName': serverName,
        'itemId': itemId,
        'role': role.name,
        'isPrimary': isPrimary,
        'isFailover': isFailover,
        'is4K': is4K,
        'failedPlaybackCount': failedPlaybackCount,
        'isSuppressed': isSuppressed,
      };

  factory ServerMediaCopy.fromJson(Map<String, dynamic> json) =>
      ServerMediaCopy(
        serverId: json['serverId'] as String? ?? '',
        serverName: json['serverName'] as String? ?? '',
        itemId: json['itemId'] as String? ?? '',
        role: ServerRole.values.firstWhere(
          (r) => r.name == json['role'],
          orElse: () => ServerRole.primary,
        ),
        isPrimary: json['isPrimary'] as bool? ?? true,
        isFailover: json['isFailover'] as bool? ?? false,
        is4K: json['is4K'] as bool? ?? false,
        failedPlaybackCount: (json['failedPlaybackCount'] as num?)?.toInt() ?? 0,
        isSuppressed: json['isSuppressed'] as bool? ?? false,
        rawData: json['rawData'] as Map<String, dynamic>? ?? const {},
      );
}

/// Unified cross-server media item merging copies across servers.
class CrossServerMediaItem {
  final String crossServerKey;
  final String selectedServerId;
  final String primaryItemId;
  final List<ServerMediaCopy> availableCopies;
  final String metadataSourceServerId;
  final AggregatedItem primaryItem;

  const CrossServerMediaItem({
    required this.crossServerKey,
    required this.selectedServerId,
    required this.primaryItemId,
    required this.availableCopies,
    required this.metadataSourceServerId,
    required this.primaryItem,
  });

  List<String> get availableServerIds =>
      availableCopies.map((c) => c.serverId).toList();
}

/// Steps in the updated 8-step onboarding and synchronization flow.
enum SyncStep {
  preparation(0, 'Data Preparation and Synchronisation'),
  movies(1, 'Movies'),
  series(2, 'Series'),
  genres(3, 'Genres'),
  viewingLab(4, 'Viewing Experience Lab'),
  moodsAndVibes(5, 'Moods and Vibes'),
  perfectExperience(6, 'Perfect Experience'),
  reviewAndCompletion(7, 'Profile Review and Completion');

  final int stepIndex;
  final String title;
  const SyncStep(this.stepIndex, this.title);
}

/// Resumable synchronisation state machine progress.
class SyncProgressState {
  final SyncStep currentStep;
  final double progressPercent; // 0.0 to 100.0
  final int recordsProcessed;
  final int totalRecords;
  final String statusMessage;
  final String? failoverMessage;
  final bool isCompleted;
  final bool isCancelled;
  final String? errorMessage;
  final Set<SyncStep> completedSteps;
  final DateTime lastUpdatedUtc;

  const SyncProgressState({
    this.currentStep = SyncStep.preparation,
    this.progressPercent = 0.0,
    this.recordsProcessed = 0,
    this.totalRecords = 0,
    this.statusMessage = 'Retrieving stream choices to personalize your viewing experience. This may take a minute - it will be with the wait.',
    this.failoverMessage,
    this.isCompleted = false,
    this.isCancelled = false,
    this.errorMessage,
    this.completedSteps = const {},
    required this.lastUpdatedUtc,
  });

  SyncProgressState copyWith({
    SyncStep? currentStep,
    double? progressPercent,
    int? recordsProcessed,
    int? totalRecords,
    String? statusMessage,
    String? failoverMessage,
    bool? isCompleted,
    bool? isCancelled,
    String? errorMessage,
    Set<SyncStep>? completedSteps,
    DateTime? lastUpdatedUtc,
  }) =>
      SyncProgressState(
        currentStep: currentStep ?? this.currentStep,
        progressPercent: progressPercent ?? this.progressPercent,
        recordsProcessed: recordsProcessed ?? this.recordsProcessed,
        totalRecords: totalRecords ?? this.totalRecords,
        statusMessage: statusMessage ?? this.statusMessage,
        failoverMessage: failoverMessage ?? this.failoverMessage,
        isCompleted: isCompleted ?? this.isCompleted,
        isCancelled: isCancelled ?? this.isCancelled,
        errorMessage: errorMessage ?? this.errorMessage,
        completedSteps: completedSteps ?? this.completedSteps,
        lastUpdatedUtc: lastUpdatedUtc ?? this.lastUpdatedUtc,
      );

  Map<String, dynamic> toJson() => {
        'currentStep': currentStep.name,
        'progressPercent': progressPercent,
        'recordsProcessed': recordsProcessed,
        'totalRecords': totalRecords,
        'statusMessage': statusMessage,
        'failoverMessage': failoverMessage,
        'isCompleted': isCompleted,
        'isCancelled': isCancelled,
        'errorMessage': errorMessage,
        'completedSteps': completedSteps.map((s) => s.name).toList(),
        'lastUpdatedUtc': lastUpdatedUtc.toIso8601String(),
      };

  factory SyncProgressState.fromJson(Map<String, dynamic> json) =>
      SyncProgressState(
        currentStep: SyncStep.values.firstWhere(
          (s) => s.name == json['currentStep'],
          orElse: () => SyncStep.preparation,
        ),
        progressPercent: (json['progressPercent'] as num?)?.toDouble() ?? 0.0,
        recordsProcessed: (json['recordsProcessed'] as num?)?.toInt() ?? 0,
        totalRecords: (json['totalRecords'] as num?)?.toInt() ?? 0,
        statusMessage: json['statusMessage'] as String? ?? '',
        failoverMessage: json['failoverMessage'] as String?,
        isCompleted: json['isCompleted'] as bool? ?? false,
        isCancelled: json['isCancelled'] as bool? ?? false,
        errorMessage: json['errorMessage'] as String?,
        completedSteps: (json['completedSteps'] as List<dynamic>? ?? [])
            .map((e) => SyncStep.values.firstWhere(
                  (s) => s.name == e,
                  orElse: () => SyncStep.preparation,
                ))
            .toSet(),
        lastUpdatedUtc: json['lastUpdatedUtc'] != null
            ? DateTime.tryParse(json['lastUpdatedUtc'] as String) ?? DateTime.now().toUtc()
            : DateTime.now().toUtc(),
      );
}

/// An individual recommendation with a grounded explainability reason and multi-server metadata.
class RecommendationItem {
  final AggregatedItem item;
  final double score; // 0.0 - 100.0
  final String reason;
  final String? badgeText;
  final Map<String, double> breakdown;
  final String crossServerKey;
  final String selectedServerId;
  final String jellyfinItemId;
  final List<String> availableServerIds;
  final String metadataSourceServerId;
  final String groundedExplanation;

  RecommendationItem({
    required this.item,
    required this.score,
    required this.reason,
    this.badgeText,
    this.breakdown = const {},
    String? crossServerKey,
    String? selectedServerId,
    String? jellyfinItemId,
    List<String>? availableServerIds,
    String? metadataSourceServerId,
    String? groundedExplanation,
  })  : crossServerKey = crossServerKey ?? item.id,
        selectedServerId = selectedServerId ?? item.serverId,
        jellyfinItemId = jellyfinItemId ?? item.id,
        availableServerIds = availableServerIds ?? [item.serverId],
        metadataSourceServerId = metadataSourceServerId ?? item.serverId,
        groundedExplanation = groundedExplanation ?? reason;
}

/// Types of personalized and curated recommendation home rows.
enum PersonalizationRowType {
  recommendedForYou('recommendedForYou', 'Recommended for You'),
  becauseYouWatched('becauseYouWatched', 'Because You Watched'),
  seriesYouMightBinge('seriesYouMightBinge', 'Series You Might Binge'),
  moodMatch('moodMatch', 'Matching Your Mood'),
  hiddenGems('hiddenGems', 'Hidden Gems for You'),
  wellKnownTitles('wellKnownTitles', 'Well-Known Titles You May Have Missed'),
  somethingDifferent('somethingDifferent', 'Something Different'),
  newInLibraryMatchesTaste('newInLibraryMatchesTaste', 'New & Matches Your Taste'),
  oscarWinners('oscarWinners', 'Oscar-Winning Performances'),
  fromNomineeToWinner('fromNomineeToWinner', 'From Nominee to Winner'),
  careerMilestones('careerMilestones', 'Career Milestones'),
  awardSeasonEssentials('awardSeasonEssentials', 'Award Season Essentials'),
  genreDeepCuts('genreDeepCuts', 'Genre Deep Cuts'),
  beforeTheyWereFamous('beforeTheyWereFamous', 'Before They Were Famous');

  final String key;
  final String defaultTitle;
  const PersonalizationRowType(this.key, this.defaultTitle);
}
